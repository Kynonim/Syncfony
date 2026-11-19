pub mod routes {
  use std::path::PathBuf;
  use std::sync::Arc;
  use axum::{Json, Router, body::Body, extract::{Multipart, Path, Query, Request, State}, http::StatusCode, middleware::{self, Next}, response::{IntoResponse, Response}, routing::{delete, get, post}};
  use chrono::{DateTime, Utc};
  use sha2::{Digest, Sha256};
  use tokio::io::AsyncWriteExt;
  use tower_http::services::ServeFile;
  use crate::{database::Database, error::AppError, models::{BackfillResponse, CheckHashesRequest, CheckHashesResponse, ListQuery, Media, MediaPage, MediaResponse, MediaThumb, ReconcileQuery, ReconcileResponse, StatsResponse, UploadResponse}, storage::Storage};

  #[derive(Clone)]
  pub struct AppState {
    pub db: Database,
    pub storage: Arc<Storage>,
    pub auth_token: Option<String>
  }

  pub fn router(state: AppState) -> Router {
    let protected = Router::new()
      .route("/api/upload", post(upload))
      .route("/api/assets", get(lists_media))
      .route("/api/assets/check", post(check_hashes))
      .route("/api/assets/hashes", get(list_hashes))
      .route("/api/assets/backfill", post(backfill_metadata))
      .route("/api/maintenance/reconcile", post(reconcile))
      .route("/api/assets/{id}", delete(delete_media))
      .route("/api/assets/{id}/thumb", get(get_thumbnail))
      .route("/api/assets/{id}/file", get(get_original))
      .route("/api/assets/{id}/live", get(get_live))
      .route("/api/stats", get(get_stats))
      .layer(middleware::from_fn_with_state(state.clone(), auth_middleware));

    Router::new()
      .route("/", get(kernel))
      .route("/api/health", get(health))
      .merge(protected)
      .with_state(state)
  }

  async fn auth_middleware(State(state): State<AppState>, req: Request, next: Next) -> Result<Response, AppError> {
    if let Some(expected) = &state.auth_token {
      let header_token = req.headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer ").or(Some(s)));

      // Token lewat query hanya untuk endpoint baca (mis. pemutar media yang
      // tidak bisa mengirim header kustom), bukan untuk upload/delete.
      let query_token = if req.method() == axum::http::Method::GET {
        req.uri().query().and_then(|q| {
          q.split('&').find_map(|pair| pair.strip_prefix("token="))
        })
      } else {
        None
      };

      let provided = header_token.or(query_token).unwrap_or("");
      if provided != expected {
        return Err(AppError::Unauthorized("Invalid or missing token".into()));
      }
    }
    Ok(next.run(req).await)
  }

  async fn kernel() -> &'static str {
    r#"
      GET /api/health
      GET /api/stats
      GET /api/assets?limit=&offset=
      GET /api/assets/hashes
      POST /api/assets/check
      DELETE /api/assets/:id
      GET /api/assets/:id/thumb
      GET /api/assets/:id/file
      GET /api/assets/:id/live
      POST /api/upload
    "#
  }

  async fn health() -> &'static str {
    "https://rikyripaldo.my.id"
  }

  #[derive(Default)]
  struct PendingUpload {
    file: Option<PathBuf>,
    live: Option<PathBuf>,
    filename: String,
    content_type: String,
    hash: Option<String>,
    size: i64,
    timestamp: Option<DateTime<Utc>>,
    device_id: Option<String>
  }

  impl PendingUpload {
    fn new() -> Self {
      Self {
        filename: "unknown".to_string(),
        content_type: "application/octet-stream".to_string(),
        ..Default::default()
      }
    }

    async fn cleanup(&mut self) {
      if let Some(path) = self.file.take() {
        let _ = tokio::fs::remove_file(path).await;
      }
      if let Some(path) = self.live.take() {
        let _ = tokio::fs::remove_file(path).await;
      }
    }
  }

  async fn upload(State(state): State<AppState>, multipart: Multipart) -> Result<Json<UploadResponse>, AppError> {
    let mut pending = PendingUpload::new();
    let result = upload_inner(&state, multipart, &mut pending).await;
    pending.cleanup().await;
    result
  }

  /// Membaca multipart secara streaming ke file sementara sambil menghitung
  /// SHA-256, sehingga upload video besar tidak menahan seluruh isi di RAM.
  async fn upload_inner(state: &AppState, mut multipart: Multipart, pending: &mut PendingUpload) -> Result<Json<UploadResponse>, AppError> {
    while let Some(mut field) = multipart.next_field().await? {
      let name = field.name().unwrap_or("").to_string();
      match name.as_str() {
        "file" => {
          pending.filename = field.file_name().unwrap_or("unknown").to_string();
          pending.content_type = field.content_type().unwrap_or("application/octet-stream").to_string();

          let tmp = state.storage.temp_file("upload");
          let mut out = tokio::fs::File::create(&tmp).await?;
          let mut hasher = Sha256::new();
          let mut size: i64 = 0;
          while let Some(chunk) = field.chunk().await? {
            hasher.update(&chunk);
            size += chunk.len() as i64;
            out.write_all(&chunk).await?;
          }
          out.flush().await?;
          drop(out);

          pending.hash = Some(hex::encode(hasher.finalize()));
          pending.size = size;
          pending.file = Some(tmp);
        }
        "live_file" => {
          let tmp = state.storage.temp_file("live");
          let mut out = tokio::fs::File::create(&tmp).await?;
          let mut written: i64 = 0;
          while let Some(chunk) = field.chunk().await? {
            written += chunk.len() as i64;
            out.write_all(&chunk).await?;
          }
          out.flush().await?;
          drop(out);

          if written > 0 {
            pending.live = Some(tmp);
          } else {
            let _ = tokio::fs::remove_file(&tmp).await;
          }
        }
        "timestamp" => {
          if let Ok(val) = field.text().await {
            if let Ok(dt) = DateTime::parse_from_rfc3339(val.trim()) {
              pending.timestamp = Some(dt.with_timezone(&Utc));
            } else if let Ok(ms) = val.trim().parse::<i64>() {
              if let Some(dt) = DateTime::from_timestamp_millis(ms) {
                pending.timestamp = Some(dt);
              }
            }
          }
        }
        "device_id" => {
          if let Ok(val) = field.text().await {
            let trimmed = val.trim().to_string();
            if !trimmed.is_empty() {
              pending.device_id = Some(trimmed);
            }
          }
        }
        _ => {}
      }
    }

    let hash = pending.hash.clone().ok_or_else(|| AppError::BadRequest("Not file field".into()))?;
    if pending.size == 0 {
      return Err(AppError::BadRequest("Empty file".into()));
    }
    let temp_src = pending.file.clone().ok_or_else(|| AppError::Internal("Missing temporary file".into()))?;

    let existing = state.db.query("select * from media where hash = $h limit 1").bind(("h", hash.clone())).await?.take::<Option<Media>>(0)?;
    if let Some(media) = existing {
      let id = media.id.map(|x| match &x.key {
        surrealdb::types::RecordIdKey::String(s) => s.clone(),
        other => format!("{:?}", other)
      }).unwrap_or_default();
      return Ok(Json(UploadResponse { id, hash, deduplicated: true }));
    }

    let extension = guess_extension(&pending.filename, &pending.content_type);
    let media_path = state.storage.media_path();
    let relative_path = state.storage.media_file_path(&media_path, &hash, &extension);
    let destination = state.storage.absolute_path(&relative_path);
    if let Some(parent) = destination.parent() {
      tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::rename(&temp_src, &destination).await?;

    let has_live = if let Some(live_src) = pending.live.clone() {
      let live_relative = state.storage.live_file_path(&media_path, &hash);
      let live_destination = state.storage.absolute_path(&live_relative);
      if let Some(parent) = live_destination.parent() {
        tokio::fs::create_dir_all(parent).await?;
      }
      tokio::fs::rename(&live_src, &live_destination).await?;
      true
    } else {
      false
    };

    let media_thumb = state.storage
      .generate_thumbnail(&media_path, &hash, &destination, &pending.content_type)
      .await
      .ok()
      .flatten()
      .unwrap_or_else(MediaThumb::null);
    let has_thumb = media_thumb.width > 0 && media_thumb.size > 0;

    let exif_meta = if pending.content_type.starts_with("image/") {
      crate::metadata::read_image_exif(&destination)
    } else if pending.content_type.starts_with("video/") {
      crate::metadata::probe_video(&destination)
    } else {
      None
    }
    .unwrap_or_default();

    let timestamp = pending
      .timestamp
      .or(exif_meta.captured_at)
      .unwrap_or_else(Utc::now);

    let media = Media {
      id: None,
      hash: hash.clone(),
      original_name: pending.filename.clone(),
      mimetype: pending.content_type.clone(),
      size: [media_thumb.size, pending.size],
      extension,
      aspect_ratio: [
        if media_thumb.width > 0 { Some(media_thumb.width) } else { None },
        if media_thumb.height > 0 { Some(media_thumb.height) } else { None }
      ],
      storage_path: media_path,
      has_thumb,
      has_live: Some(has_live),
      duration: media_thumb.duration,
      device_id: pending.device_id.clone(),
      device_name: exif_meta.device_name.clone(),
      lens: exif_meta.lens.clone(),
      focal_length: exif_meta.focal_length.clone(),
      aperture: exif_meta.aperture.clone(),
      exposure: exif_meta.exposure.clone(),
      iso: exif_meta.iso,
      software: exif_meta.software.clone(),
      timestamp
    };

    let created = state.db.create::<Option<Media>>("media").content(media).await?;
    let created = created.ok_or_else(|| AppError::Internal("Failed to create".into()))?;
    let id = created.id.map(|x| match &x.key {
      surrealdb::types::RecordIdKey::String(s) => s.clone(),
      other => format!("{:?}", other)
    }).unwrap_or_default();
    Ok(Json(UploadResponse { id, hash, deduplicated: false }))
  }

  async fn check_hashes(State(state): State<AppState>, Json(payload): Json<CheckHashesRequest>) -> Result<Json<CheckHashesResponse>, AppError> {
    if payload.hashes.is_empty() {
      return Ok(Json(CheckHashesResponse { existing: vec![] }));
    }
    let found = state.db
      .query("select value hash from media where hash in $hashes")
      .bind(("hashes", payload.hashes))
      .await?
      .take::<Vec<String>>(0)?;
    Ok(Json(CheckHashesResponse { existing: found }))
  }

  async fn list_hashes(State(state): State<AppState>) -> Result<Json<Vec<String>>, AppError> {
    let hashes = state.db.query("select value hash from media").await?.take::<Vec<String>>(0)?;
    Ok(Json(hashes))
  }

  /// Mengisi ulang metadata kamera untuk media yang diunggah sebelum fitur EXIF
  /// ada. Hanya file yang belum punya data perangkat/lensa yang diproses.
  /// Mencari file di disk yang tidak punya baris di database (yatim) dan baris
  /// yang filenya hilang. Default `dry_run=true` sehingga hanya melapor.
  async fn reconcile(
    State(state): State<AppState>,
    Query(query): Query<ReconcileQuery>
  ) -> Result<Json<ReconcileResponse>, AppError> {
    let dry_run = query.dry_run.unwrap_or(true);
    let items = state.db.query("select * from media").await?.take::<Vec<Media>>(0)?;

    let mut expected = std::collections::HashSet::new();
    let mut missing_files = 0usize;

    for media in &items {
      let file = state.storage.media_file_path(&media.storage_path, &media.hash, &media.extension);
      let thumb = state.storage.thumb_file_path(&media.storage_path, &media.hash);
      let live = state.storage.live_file_path(&media.storage_path, &media.hash);

      if !tokio::fs::try_exists(state.storage.absolute_path(&file))
        .await
        .unwrap_or(false)
      {
        missing_files += 1;
      }

      expected.insert(file);
      if media.has_thumb {
        expected.insert(thumb);
      }
      if media.has_live.unwrap_or(false) {
        expected.insert(live);
      }
    }

    let files = state.storage.list_relative_files().await;
    let scanned_files = files.len();
    let mut orphan_files = 0usize;
    let mut removed = 0usize;

    for relative in files {
      if relative.starts_with(".tmp/") || expected.contains(&relative) {
        continue;
      }
      orphan_files += 1;
      if !dry_run && state.storage.delete_file(&relative).await.is_ok() {
        removed += 1;
      }
    }

    tracing::info!(
      "reconcile: {scanned_files} file dipindai, {orphan_files} yatim, {missing_files} hilang, {removed} dihapus (dry_run={dry_run})"
    );

    Ok(Json(ReconcileResponse {
      dry_run,
      scanned_files,
      orphan_files,
      missing_files,
      removed
    }))
  }

  async fn backfill_metadata(State(state): State<AppState>) -> Result<Json<BackfillResponse>, AppError> {
    let items = state.db.query("select * from media").await?.take::<Vec<Media>>(0)?;
    let scanned = items.len();
    let mut updated = 0usize;

    for media in items {
      if media.device_name.is_some() || media.lens.is_some() || media.software.is_some() {
        continue;
      }

      let file_path = state.storage.media_file_path(&media.storage_path, &media.hash, &media.extension);
      let absolute = state.storage.absolute_path(&file_path);
      if !tokio::fs::try_exists(&absolute).await.unwrap_or(false) {
        continue;
      }

      let meta = if media.mimetype.starts_with("image/") {
        crate::metadata::read_image_exif(&absolute)
      } else if media.mimetype.starts_with("video/") {
        crate::metadata::probe_video(&absolute)
      } else {
        None
      };

      let Some(meta) = meta else { continue };
      if meta.device_name.is_none() && meta.lens.is_none() && meta.software.is_none() {
        continue;
      }

      let Some(record_id) = media.id.as_ref() else { continue };

      state.db
        .query(
          "update $id set\n             device_name = $device,\n             lens = $lens,\n             focal_length = $focal,\n             aperture = $aperture,\n             exposure = $exposure,\n             iso = $iso,\n             software = $software"
        )
        .bind(("id", record_id.clone()))
        .bind(("device", meta.device_name))
        .bind(("lens", meta.lens))
        .bind(("focal", meta.focal_length))
        .bind(("aperture", meta.aperture))
        .bind(("exposure", meta.exposure))
        .bind(("iso", meta.iso))
        .bind(("software", meta.software))
        .await?;
      updated += 1;
    }

    tracing::info!("backfill metadata: {} media dipindai, {} diperbarui", scanned, updated);
    Ok(Json(BackfillResponse { scanned, updated }))
  }

  /// Menghapus file lebih dahulu, baru metadata. Jika penghapusan file gagal,
  /// metadata tetap ada sehingga tidak meninggalkan file yatim di disk.
  async fn delete_media(State(state): State<AppState>, Path(id): Path<String>) -> Result<StatusCode, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;

    let file_path = state.storage.media_file_path(&media.storage_path, &media.hash, &media.extension);
    state.storage.delete_file(&file_path).await?;

    if media.has_thumb {
      let thumb_path = state.storage.thumb_file_path(&media.storage_path, &media.hash);
      state.storage.delete_file(&thumb_path).await?;
    }
    if media.has_live.unwrap_or(false) {
      let live_path = state.storage.live_file_path(&media.storage_path, &media.hash);
      state.storage.delete_file(&live_path).await?;
    }

    let deleted = state.db.delete::<Option<Media>>(("media", id.as_str())).await?;
    if deleted.is_none() {
      return Err(AppError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
  }

  async fn get_stats(State(state): State<AppState>) -> Result<Json<StatsResponse>, AppError> {
    // Jalur cepat: hanya mengambil kolom ukuran, bukan seluruh dokumen.
    if let Ok(mut response) = state.db.query("select value size from media").await {
      if let Ok(sizes) = response.take::<Vec<Vec<i64>>>(0) {
        let mut total_size = 0i64;
        let mut thumb_size = 0i64;
        for size in &sizes {
          if let Some(thumb) = size.first() {
            thumb_size += *thumb;
          }
          if let Some(original) = size.get(1) {
            total_size += *original;
          }
        }
        return Ok(Json(StatsResponse { total_count: sizes.len(), total_size, thumb_size }));
      }
    }

    // Fallback jika bentuk hasil query berbeda.
    let assets = state.db.select::<Vec<Media>>("media").await?;
    let mut total_size = 0i64;
    let mut thumb_size = 0i64;
    for asset in &assets {
      thumb_size += asset.size[0];
      total_size += asset.size[1];
    }
    Ok(Json(StatsResponse { total_count: assets.len(), total_size, thumb_size }))
  }

  async fn lists_media(State(state): State<AppState>, Query(query): Query<ListQuery>) -> Result<Json<MediaPage>, AppError> {
    let limit = query.limit.unwrap_or(100).clamp(1, 500);
    let offset = query.offset.unwrap_or(0).max(0);

    // Susun filter secara dinamis; hanya parameter yang dipakai yang di-bind.
    let mut conditions = vec!["true".to_string()];
    let text_filter = query
      .q
      .as_ref()
      .map(|value| value.trim().to_lowercase())
      .filter(|value| !value.is_empty());
    if text_filter.is_some() {
      conditions.push("string::lowercase(original_name) CONTAINS $q".to_string());
    }

    let kind_filter = match query.kind.as_deref() {
      Some("image") => Some("image/".to_string()),
      Some("video") => Some("video/".to_string()),
      _ => None
    };
    if kind_filter.is_some() {
      conditions.push("mimetype CONTAINS $kind".to_string());
    }

    let where_clause = conditions.join(" AND ");

    let mut assets_query = state
      .db
      .query(format!(
        "select * from media where {where_clause} order by timestamp desc limit $limit start $offset"
      ))
      .bind(("limit", limit + 1))
      .bind(("offset", offset));
    if let Some(value) = &text_filter {
      assets_query = assets_query.bind(("q", value.clone()));
    }
    if let Some(value) = &kind_filter {
      assets_query = assets_query.bind(("kind", value.clone()));
    }

    let mut assets = assets_query.await?.take::<Vec<Media>>(0)?;
    let has_more = assets.len() as i64 > limit;
    if has_more {
      assets.truncate(limit as usize);
    }

    let mut count_query = state
      .db
      .query(format!("select count() as total from media where {where_clause} group all"));
    if let Some(value) = &text_filter {
      count_query = count_query.bind(("q", value.clone()));
    }
    if let Some(value) = &kind_filter {
      count_query = count_query.bind(("kind", value.clone()));
    }

    let total = match count_query.await {
      Ok(mut response) => response.take::<Option<i64>>((0, "total")).ok().flatten(),
      Err(_) => None
    };

    Ok(Json(MediaPage {
      items: assets.into_iter().map(MediaResponse::from).collect(),
      total,
      limit,
      offset,
      has_more
    }))
  }

  async fn get_thumbnail(State(state): State<AppState>, Path(id): Path<String>) -> Result<Response, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;
    let thumb_path = state.storage.thumb_file_path(&media.storage_path, &media.hash);
    let path = state.storage.absolute_path(&thumb_path);
    let bytes = tokio::fs::read(&path).await.map_err(|_| AppError::NotFound)?;
    Ok(([(axum::http::header::CONTENT_TYPE, "image/jpeg")], bytes).into_response())
  }

  async fn get_original(State(state): State<AppState>, Path(id): Path<String>, req: Request<Body>) -> Result<Response, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;
    let file_path = state.storage.media_file_path(&media.storage_path, &media.hash, &media.extension);
    let path = state.storage.absolute_path(&file_path);
    if !tokio::fs::try_exists(&path).await.unwrap_or(false) {
      return Err(AppError::NotFound);
    }
    let res = ServeFile::new(&path)
      .try_call(req)
      .await
      .map_err(|e| AppError::Internal(e.to_string()))?;
    Ok(res.into_response())
  }

  async fn get_live(State(state): State<AppState>, Path(id): Path<String>, req: Request<Body>) -> Result<Response, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;
    if !media.has_live.unwrap_or(false) {
      return Err(AppError::NotFound);
    }
    let live_path = state.storage.live_file_path(&media.storage_path, &media.hash);
    let path = state.storage.absolute_path(&live_path);
    if !tokio::fs::try_exists(&path).await.unwrap_or(false) {
      return Err(AppError::NotFound);
    }
    let res = ServeFile::new(&path)
      .try_call(req)
      .await
      .map_err(|e| AppError::Internal(e.to_string()))?;
    Ok(res.into_response())
  }

  fn guess_extension(filename: &str, mimetype: &str) -> String {
    if let Some(pos) = filename.rfind('.') {
      let ext = &filename[pos + 1..];
      if ext.len() >= 2 && ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        return ext.to_lowercase();
      }
    }
    match mimetype {
      "image/jpeg" => "jpg",
      "image/png" => "png",
      "image/webp" => "webp",
      "image/gif" => "gif",
      "image/heic" | "image/heif" => "heic",
      "video/mp4" => "mp4",
      "video/quicktime" => "mov",
      "video/x-matroska" => "mkv",
      "video/webm" => "webm",
      _ => "bin",
    }.to_string()
  }
}

pub mod storage {
  use std::path::PathBuf;
  use chrono::Utc;
  use image::ImageFormat;
  use sha2::{Digest, Sha256};
  use crate::models::MediaThumb;

  pub struct Storage {
    pub root: PathBuf
  }

  impl Storage {
    pub fn new(root: impl Into<PathBuf>) -> Self {
      Self { root: root.into() }
    }

    pub async fn init(&self) -> anyhow::Result<()> {
      tokio::fs::create_dir_all(self.root.join("media")).await?;
      tokio::fs::create_dir_all(self.root.join(".cache")).await?;
      tokio::fs::create_dir_all(self.temp_dir()).await?;
      Ok(())
    }

    pub fn temp_dir(&self) -> PathBuf {
      self.root.join(".tmp")
    }

    /// Path sementara unik untuk streaming upload sebelum di-rename ke lokasi akhir.
    pub fn temp_file(&self, tag: &str) -> PathBuf {
      self.temp_dir().join(format!("{}-{}", tag, uuid::Uuid::new_v4()))
    }

    pub fn media_path(&self) -> String {
      let now = Utc::now();
      format!("media/{}/{:02}", now.format("%Y"), now.format("%m"))
    }

    pub fn thumb_path(&self, media_path: &str) -> String {
      format!("{}/.thumbs", media_path)
    }

    pub fn media_file_path(&self, media_path: &str, hash: &str, extension: &str) -> String {
      format!("{}/{}.{}", media_path, hash, extension)
    }

    pub fn thumb_file_path(&self, media_path: &str, hash: &str) -> String {
      format!("{}/{}.jpg", self.thumb_path(media_path), hash)
    }

    pub fn live_file_path(&self, media_path: &str, hash: &str) -> String {
      format!("{}/{}_live.mov", media_path, hash)
    }

    pub fn absolute_path(&self, path: &str) -> PathBuf {
      self.root.join(path)
    }

    /// Menghapus file sementara sisa proses upload yang terhenti/crash.
    pub async fn cleanup_temp(&self) -> anyhow::Result<usize> {
      let mut removed = 0usize;
      if let Ok(mut entries) = tokio::fs::read_dir(self.temp_dir()).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
          if tokio::fs::remove_file(entry.path()).await.is_ok() {
            removed += 1;
          }
        }
      }
      Ok(removed)
    }

    /// Semua file di dalam storage, sebagai path relatif terhadap root.
    pub async fn list_relative_files(&self) -> Vec<String> {
      let mut result = Vec::new();
      let mut stack = vec![self.root.clone()];

      while let Some(current) = stack.pop() {
        let Ok(mut entries) = tokio::fs::read_dir(&current).await else { continue };
        while let Ok(Some(entry)) = entries.next_entry().await {
          let path = entry.path();
          let is_dir = entry.file_type().await.map(|kind| kind.is_dir()).unwrap_or(false);
          if is_dir {
            stack.push(path);
          } else if let Ok(relative) = path.strip_prefix(&self.root) {
            result.push(
              relative
                .to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/")
            );
          }
        }
      }

      result
    }

    pub async fn write(&self, path: &str, data: &[u8]) -> anyhow::Result<()> {
      let path = self.absolute_path(path);
      if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
      }
      tokio::fs::write(path, data).await?;
      Ok(())
    }

    pub async fn delete_file(&self, path: &str) -> anyhow::Result<()> {
      let full = self.absolute_path(path);
      match tokio::fs::remove_file(full).await {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
      }
    }

    pub async fn generate_thumbnail(&self, media_path: &str, hash: &str, source: &std::path::Path, mime: &str) -> anyhow::Result<Option<MediaThumb>> {
      let thumb_path = self.thumb_file_path(media_path, hash);
      let thumb_absolute = self.absolute_path(&thumb_path);
      if let Some(parent) = thumb_absolute.parent() {
        tokio::fs::create_dir_all(parent).await?;
      }

      if mime.starts_with("image/") {
        let source = source.to_path_buf();
        let thumb_absolute = thumb_absolute.clone();
        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<MediaThumb> {
          let data = std::fs::read(&source)?;
          let img = if is_heic_format(&data) {
            heif::decode(&data).map_err(|e| anyhow::anyhow!("HEIC Decode: {}", e))
          } else {
            image::load_from_memory(&data).map_err(|e| anyhow::anyhow!("Decode: {}", e))
          }?;
          let (width, height) = (img.width() as i32, img.height() as i32);
          let thumb = img.thumbnail(512, 512);
          if let Some(parent) = thumb_absolute.parent() {
            std::fs::create_dir_all(parent)?;
          }
          thumb.save_with_format(&thumb_absolute, ImageFormat::Jpeg)?;
          let thumb_size = std::fs::metadata(&thumb_absolute)?.len() as i64;
          Ok(MediaThumb { width, height, size: thumb_size, duration: None })
        }).await??;
        Ok(Some(result))
      } else if mime.starts_with("video/") {
        let source = source.to_path_buf();
        let thumb_absolute = thumb_absolute.clone();

        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<MediaThumb> {
          let source_str = source.to_str().ok_or_else(|| anyhow::anyhow!("Invalid video path"))?;
          let output = std::process::Command::new("ffprobe").args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,duration",
            "-of", "json",
            source_str
          ]).output()?;
          let json = serde_json::from_slice::<serde_json::Value>(&output.stdout)?;
          let stream = &json["streams"][0];
          let width = stream["width"].as_i64().unwrap_or(0) as i32;
          let height = stream["height"].as_i64().unwrap_or(0) as i32;
          let duration = stream["duration"].as_str().and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
          let seek_time = if duration >= 1.0 {"00:00:01"} else {"00:00:00"};

          let status = std::process::Command::new("ffmpeg").args([
            "-ss", seek_time,
            "-i", source_str,
            "-vframes", "1",
            "-vf", "scale=512:-1",
            "-y", thumb_absolute.to_str().ok_or_else(|| anyhow::anyhow!("Invalid thumbnail path"))?
          ]).status()?;
          if !status.success() {
            return Err(anyhow::anyhow!("FFMPEG video extract error"));
          }

          let thumb_size = std::fs::metadata(&thumb_absolute)?.len() as i64;
          Ok(MediaThumb { width, height, size: thumb_size, duration: Some(duration) })
        }).await??;

        Ok(Some(result))
      } else {
        Ok(None)
      }
    }
  }

  fn is_heic_format(bytes: &[u8]) -> bool {
    if bytes.len() < 12 { return false; }
    if &bytes[4..8] != b"ftyp" { return false; }
    matches!(&bytes[8..12], b"heic" | b"heix" | b"mif1" | b"msf1")
  }

  pub fn hash_bytes(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
  }
}

pub mod metadata {
  use std::path::Path;
  use chrono::{DateTime, NaiveDateTime, Utc};
  use crate::models::MediaExif;

  fn clean(value: String) -> Option<String> {
    let trimmed = value.trim().trim_matches('"').trim();
    if trimmed.is_empty() { None } else { Some(trimmed.to_string()) }
  }

  /// Memetakan tag EXIF yang sudah diparse ke struct kita.
  fn from_exif(exif: &exif::Exif) -> MediaExif {
    let text = |tag: exif::Tag| -> Option<String> {
      exif
        .fields()
        .find(|field| field.tag == tag)
        .and_then(|field| clean(field.display_value().to_string()))
    };
    let with_unit = |tag: exif::Tag| -> Option<String> {
      exif
        .fields()
        .find(|field| field.tag == tag)
        .map(|field| field.display_value().with_unit(exif).to_string())
        .and_then(clean)
    };

    let make = text(exif::Tag::Make);
    let model = text(exif::Tag::Model);
    let device_name = match (make, model) {
      (Some(make), Some(model)) => {
        if model.to_lowercase().contains(&make.to_lowercase()) {
          Some(model)
        } else {
          Some(format!("{} {}", make, model))
        }
      }
      (None, Some(model)) => Some(model),
      (Some(make), None) => Some(make),
      _ => None,
    };

    let iso = exif
      .fields()
      .find(|field| field.tag == exif::Tag::PhotographicSensitivity)
      .and_then(|field| field.value.get_uint(0))
      .map(|value| value as i64);

    let captured_at = text(exif::Tag::DateTimeOriginal)
      .or_else(|| text(exif::Tag::DateTime))
      .and_then(|value| NaiveDateTime::parse_from_str(&value, "%Y:%m:%d %H:%M:%S").ok())
      .map(|naive| DateTime::<Utc>::from_naive_utc_and_offset(naive, Utc));

    MediaExif {
      device_name,
      lens: text(exif::Tag::LensModel),
      focal_length: with_unit(exif::Tag::FocalLength),
      aperture: with_unit(exif::Tag::FNumber),
      exposure: with_unit(exif::Tag::ExposureTime),
      iso,
      software: text(exif::Tag::Software),
      captured_at,
    }
  }

  /// Membaca EXIF dari foto (JPEG/TIFF/HEIC/PNG/WebP).
  ///
  /// Strategi 1: parsing sadar-kontainer. Strategi 2 (fallback): cari blok
  /// header TIFF/EXIF mentah di dalam file — sebagian HEIC iPhone menyimpan
  /// EXIF di offset yang tidak dikenali parser kontainer.
  pub fn read_image_exif(path: &Path) -> Option<MediaExif> {
    if let Ok(file) = std::fs::File::open(path) {
      let mut reader = std::io::BufReader::new(file);
      if let Ok(exif) = exif::Reader::new().read_from_container(&mut reader) {
        let meta = from_exif(&exif);
        if meta.device_name.is_some() || meta.lens.is_some() || meta.software.is_some() {
          return Some(meta);
        }
      }
    }

    let bytes = std::fs::read(path).ok()?;
    let limit = bytes.len().min(4 * 1024 * 1024);
    let mut index = 0usize;
    while index + 4 <= limit {
      let window = &bytes[index..index + 4];
      if window == b"II\x2A\x00" || window == b"MM\x00\x2A" {
        let payload = bytes[index..].to_vec();
        if let Ok(exif) = exif::Reader::new().read_raw(payload) {
          let meta = from_exif(&exif);
          if meta.device_name.is_some() || meta.lens.is_some() {
            return Some(meta);
          }
        }
      }
      index += 1;
    }

    None
  }

  /// Membaca tag metadata video (ffprobe) — iOS menyimpan make/model di tag QuickTime.
  pub fn probe_video(path: &Path) -> Option<MediaExif> {
    let path_str = path.to_str()?;
    let output = std::process::Command::new("ffprobe").args([
      "-v", "error",
      "-show_entries", "format_tags=make,model,software,creation_time,com.apple.quicktime.make,com.apple.quicktime.model,com.apple.quicktime.software",
      "-of", "json",
      path_str
    ]).output().ok()?;

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let tags = json.get("format")?.get("tags")?;

    let tag = |keys: &[&str]| -> Option<String> {
      for key in keys {
        if let Some(value) = tags.get(*key).and_then(|item| item.as_str()) {
          if let Some(clean) = clean(value.to_string()) {
            return Some(clean);
          }
        }
      }
      None
    };

    let make = tag(&["com.apple.quicktime.make", "make"]);
    let model = tag(&["com.apple.quicktime.model", "model"]);
    let device_name = match (make, model) {
      (Some(make), Some(model)) => {
        if model.to_lowercase().contains(&make.to_lowercase()) {
          Some(model)
        } else {
          Some(format!("{} {}", make, model))
        }
      }
      (None, Some(model)) => Some(model),
      (Some(make), None) => Some(make),
      _ => None,
    };

    let captured_at = tag(&["creation_time"])
      .and_then(|value| DateTime::parse_from_rfc3339(&value).ok())
      .map(|value| value.with_timezone(&Utc));

    Some(MediaExif {
      device_name,
      lens: None,
      focal_length: None,
      aperture: None,
      exposure: None,
      iso: None,
      software: tag(&["com.apple.quicktime.software", "software"]),
      captured_at,
    })
  }
}

pub mod database {
  use std::sync::Arc;
  use surrealdb::{Surreal, engine::local::{Db, SurrealKv}};

  pub type Database = Arc<Surreal<Db>>;

  pub async fn init(path: &str) -> anyhow::Result<Database> {
    let db = Surreal::new::<SurrealKv>(path).await?;
    db.use_ns("syncfony").use_db("media").await?;
    db.query(r#"
      define table if not exists media schemafull;
      define field if not exists id on table media type record<media>;
      define field if not exists hash on table media type string;
      define field if not exists original_name on table media type string;
      define field if not exists mimetype on table media type string;
      define field if not exists extension on table media type string;
      define field if not exists aspect_ratio on table media type option<array<int, 2>>;
      define field if not exists size on table media type array<int, 2>;
      define field if not exists storage_path on table media type option<string>;
      define field if not exists device_id on table media type option<string>;
      define field if not exists has_thumb on table media type bool;
      define field if not exists has_live on table media type option<bool>;
      define field if not exists duration on table media type option<float>;
      define field if not exists device_name on table media type option<string>;
      define field if not exists lens on table media type option<string>;
      define field if not exists focal_length on table media type option<string>;
      define field if not exists aperture on table media type option<string>;
      define field if not exists exposure on table media type option<string>;
      define field if not exists iso on table media type option<int>;
      define field if not exists software on table media type option<string>;
      define field if not exists timestamp on table media type datetime;
    "#).await?;
    Ok(Arc::new(db))
  }
}

pub mod models {
  use chrono::{DateTime, Utc};
  use serde::{Deserialize, Serialize};
  use surrealdb::types::{RecordId, RecordIdKey, SurrealValue};

  #[derive(Debug, Clone, Serialize, Deserialize, SurrealValue)]
  pub struct Media {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<RecordId>,
    pub hash: String,
    pub original_name: String,
    pub mimetype: String,
    pub extension: String,
    pub aspect_ratio: [Option<i32>; 2],
    pub size: [i64; 2],
    pub storage_path: String,
    pub has_thumb: bool,
    #[surreal(default)]
    pub has_live: Option<bool>,
    pub duration: Option<f64>,
    #[surreal(default)]
    pub device_id: Option<String>,
    #[surreal(default)]
    pub device_name: Option<String>,
    #[surreal(default)]
    pub lens: Option<String>,
    #[surreal(default)]
    pub focal_length: Option<String>,
    #[surreal(default)]
    pub aperture: Option<String>,
    #[surreal(default)]
    pub exposure: Option<String>,
    #[surreal(default)]
    pub iso: Option<i64>,
    #[surreal(default)]
    pub software: Option<String>,
    pub timestamp: DateTime<Utc>
  }

  /// Metadata kamera hasil ekstraksi EXIF / tag QuickTime.
  #[derive(Debug, Clone, Default)]
  pub struct MediaExif {
    pub device_name: Option<String>,
    pub lens: Option<String>,
    pub focal_length: Option<String>,
    pub aperture: Option<String>,
    pub exposure: Option<String>,
    pub iso: Option<i64>,
    pub software: Option<String>,
    pub captured_at: Option<DateTime<Utc>>
  }

  #[derive(Debug, Serialize)]
  pub struct MediaResponse {
    pub id: String,
    pub hash: String,
    pub original_name: String,
    pub extension: String,
    pub mimetype: String,
    pub aspect_ratio: [Option<i32>; 2],
    pub size: [i64; 2],
    pub has_thumb: bool,
    pub has_live: bool,
    pub duration: Option<f64>,
    pub device_name: Option<String>,
    pub lens: Option<String>,
    pub focal_length: Option<String>,
    pub aperture: Option<String>,
    pub exposure: Option<String>,
    pub iso: Option<i64>,
    pub software: Option<String>,
    pub timestamp: DateTime<Utc>
  }

  impl From<Media> for MediaResponse {
    fn from(v: Media) -> Self {
      let id_str = v.id.as_ref().map(|id| match &id.key {
        RecordIdKey::String(s) => s.clone(),
        other => format!("{:?}", other)
      }).unwrap_or_default();
      Self {
        id: id_str,
        hash: v.hash,
        original_name: v.original_name,
        extension: v.extension,
        mimetype: v.mimetype,
        aspect_ratio: v.aspect_ratio,
        size: v.size,
        has_thumb: v.has_thumb,
        has_live: v.has_live.unwrap_or(false),
        duration: v.duration,
        device_name: v.device_name,
        lens: v.lens,
        focal_length: v.focal_length,
        aperture: v.aperture,
        exposure: v.exposure,
        iso: v.iso,
        software: v.software,
        timestamp: v.timestamp
      }
    }
  }

  #[derive(Debug, Deserialize)]
  pub struct ListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// Pencarian nama file (case-insensitive).
    pub q: Option<String>,
    /// Filter jenis: `image` atau `video`.
    pub kind: Option<String>
  }

  #[derive(Debug, Deserialize)]
  pub struct ReconcileQuery {
    pub dry_run: Option<bool>
  }

  #[derive(Debug, Serialize)]
  pub struct MediaPage {
    pub items: Vec<MediaResponse>,
    pub total: Option<i64>,
    pub limit: i64,
    pub offset: i64,
    pub has_more: bool
  }

  #[derive(Debug, Deserialize)]
  pub struct CheckHashesRequest {
    pub hashes: Vec<String>
  }

  #[derive(Debug, Serialize)]
  pub struct CheckHashesResponse {
    pub existing: Vec<String>
  }

  #[derive(Debug, Serialize)]
  pub struct StatsResponse {
    pub total_count: usize,
    pub total_size: i64,
    pub thumb_size: i64
  }

  #[derive(Debug, Serialize)]
  pub struct ReconcileResponse {
    pub dry_run: bool,
    pub scanned_files: usize,
    pub orphan_files: usize,
    pub missing_files: usize,
    pub removed: usize
  }

  #[derive(Debug, Serialize)]
  pub struct BackfillResponse {
    pub scanned: usize,
    pub updated: usize
  }

  #[derive(Debug, Serialize)]
  pub struct UploadResponse {
    pub id: String,
    pub hash: String,
    pub deduplicated: bool
  }

  #[derive(Debug, Clone)]
  pub struct MediaThumb {
    pub width: i32,
    pub height: i32,
    pub size: i64,
    pub duration: Option<f64>
  }

  impl MediaThumb {
    pub fn null() -> Self {
      Self { width: 0, height: 0, size: 0, duration: None }
    }
  }
}

pub mod error {
  use serde_json::json;
  use axum::{Json, http::StatusCode, response::IntoResponse};

  pub enum AppError {
    BadRequest(String),
    Unauthorized(String),
    Internal(String),
    NotFound
  }

  impl From<surrealdb::Error> for AppError {
    fn from(value: surrealdb::Error) -> Self {
      AppError::Internal(value.to_string())
    }
  }

  impl From<axum::extract::multipart::MultipartError> for AppError {
    fn from(value: axum::extract::multipart::MultipartError) -> Self {
      AppError::BadRequest(value.to_string())
    }
  }

  impl From<anyhow::Error> for AppError {
    fn from(value: anyhow::Error) -> Self {
      AppError::Internal(value.to_string())
    }
  }

  impl From<std::io::Error> for AppError {
    fn from(value: std::io::Error) -> Self {
      AppError::Internal(value.to_string())
    }
  }

  impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
      let (code, message) = match self {
        AppError::Internal(x) => (StatusCode::INTERNAL_SERVER_ERROR, x),
        AppError::BadRequest(x) => (StatusCode::BAD_REQUEST, x),
        AppError::Unauthorized(x) => (StatusCode::UNAUTHORIZED, x),
        AppError::NotFound => (StatusCode::NOT_FOUND, "Not Found".into())
      };
      (code, Json(json!({"error": message}))).into_response()
    }
  }
}
