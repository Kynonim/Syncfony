pub mod routes {
  use std::sync::Arc;
  use axum::{Json, Router, extract::{Multipart, Path, State}, response::{IntoResponse, Response}, routing::{get, post}};
  use chrono::Utc;
  use crate::{database::Database, error::AppError, models::{Media, MediaResponse, MediaThumb, UploadResponse}, storage::{self, Storage}};

  #[derive(Clone)]
  pub struct AppState {
    pub db: Database,
    pub storage: Arc<Storage>
  }

  pub fn router(state: AppState) -> Router {
    Router::new()
      .route("/", get(kernel))
      .route("/kernel_all", get(debug_get_all))
      .route("/api/health", get(health))
      .route("/api/upload", post(upload))
      .route("/api/assets", get(lists_media))
      .route("/api/assets/{id}/thumb", get(get_thumbnail))
      .route("/api/assets/{id}/file", get(get_original))
      .with_state(state)
  }

  async fn kernel() -> &'static str {
    r#"
      GET /api/health
      GET /api/assets
      GET /api/assets/:id/thumbnail
      GET /api/assets/:id/file
      POST /api/upload
    "#
  }

  async fn health() -> &'static str {
    "Server ok, https://rikyripaldo.my.id"
  }

  async fn debug_get_all(State(state): State<AppState>) -> Result<Json<Vec<Media>>, AppError> {
    let db = state.db.select::<Vec<Media>>("media").await?;
    Ok(Json(db))
  }

  async fn upload(State(state): State<AppState>, mut multipart: Multipart) -> Result<Json<UploadResponse>, AppError> {
    while let Some(field) = multipart.next_field().await? {
      let name = field.name().unwrap_or("").to_string();
      let filename = field.file_name().unwrap_or("unknown").to_string();
      let content_type = field.content_type().unwrap_or("application/octet-stream").to_string();

      if name == "file" {
        let data = field.bytes().await?;
        if data.is_empty() {
          return Err(AppError::BadRequest("Empty file".into()));
        }
        let hash = storage::hash_bytes(&data);
        let existing = state.db.query("select * from media where hash = $h limit 1").bind(("h", hash.clone())).await?.take::<Option<Media>>(0)?;
        if let Some(media) = existing {
          let id = media.id.map(|x| match &x.key {
            surrealdb::types::RecordIdKey::String(s) => s.clone(),
            other => format!("{:?}", other)
          }).unwrap_or_default();
          return Ok(Json(UploadResponse { id, hash, deduplicated: true }));
        }

        let extension = guess_extension(&filename, &content_type);
        let media_path = state.storage.media_path();
        let write_path = state.storage.media_file_path(&media_path, &hash, &extension);
        state.storage.write(&write_path, &data).await?;

        let media_thumb = state.storage.generate_thumbnail(&hash, &data, &content_type).await?.map(|m| m).unwrap_or(MediaThumb::null());
        let has_thumb = media_thumb.width > 0;
        let now = Utc::now();

        let media = Media {
          id: None,
          hash: hash.clone(),
          original_name: filename,
          mimetype: content_type,
          size: [media_thumb.size, data.len() as i64],
          extension: extension,
          aspect_ratio: [if media_thumb.width > 0 {Some(media_thumb.width)} else {None}, if media_thumb.height > 0 {Some(media_thumb.height)} else {None}],
          storage_path: media_path,
          has_thumb: has_thumb,
          duration: media_thumb.duration,
          device_id: None,
          timestamp: now
        };

        let created = state.db.create::<Option<Media>>("media").content(media).await?;
        let created = created.ok_or_else(|| AppError::Internal("Failed to create".into()))?;
        let id = created.id.map(|x| match &x.key {
          surrealdb::types::RecordIdKey::String(s) => s.clone(),
          other => format!("{:?}", other)
        }).unwrap_or_default();
        return Ok(Json(UploadResponse { id, hash, deduplicated: false }));
      }
    }
    Err(AppError::BadRequest("Not file field".into()))
  }

  async fn lists_media(State(state): State<AppState>) -> Result<Json<Vec<MediaResponse>>, AppError> {
    let assets = state.db.query("select * from media order by timestamp desc limit 500").await?.take::<Vec<Media>>(0)?;
    Ok(Json(assets.into_iter().map(MediaResponse::from).collect()))
  }

  async fn get_thumbnail(State(state): State<AppState>, Path(id): Path<String>) -> Result<Response, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;
    let thumb_path = state.storage.thumb_file_path(&media.storage_path, &media.hash);
    let path = state.storage.absolute_path(&thumb_path);
    let bytes = tokio::fs::read(&path).await.map_err(|_| AppError::NotFound)?;
    Ok(([(axum::http::header::CONTENT_TYPE, "image/jpeg")], bytes).into_response())
  }

  async fn get_original(State(state): State<AppState>, Path(id): Path<String>) -> Result<Response, AppError> {
    let media = state.db.select::<Option<Media>>(("media", id.as_str())).await?;
    let media = media.ok_or(AppError::NotFound)?;
    let file_path = state.storage.media_file_path(&media.storage_path, &media.hash, &media.extension);
    let path = state.storage.absolute_path(&file_path);
    let bytes = tokio::fs::read(&path).await.map_err(|_| AppError::NotFound)?;
    Ok(([(axum::http::header::CONTENT_TYPE, media.mimetype.as_str())], bytes).into_response())
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
      Ok(())
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

    pub fn absolute_path(&self, path: &str) -> PathBuf {
      self.root.join(path)
    }

    pub async fn write(&self, path: &str, data: &[u8]) -> anyhow::Result<()> {
      let path = self.absolute_path(path);
      if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
      }
      tokio::fs::write(path, data).await?;
      Ok(())
    }

    pub async fn generate_thumbnail(&self, hash: &str, data: &[u8], mime: &str) -> anyhow::Result<Option<MediaThumb>> {
      let data = data.to_vec();
      let thumb_path = self.thumb_file_path(&self.media_path(), hash);
      let thumb_absolute = self.absolute_path(&thumb_path);
      if let Some(parent) = thumb_absolute.parent() {
        tokio::fs::create_dir_all(parent).await?;
      }

      if mime.starts_with("image/") {
        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<MediaThumb> {
          //let img = image::load_from_memory(&data)?;
          let img = if is_heic_format(&data) {
            heif::decode(&data).map_err(|e| format!("HEIC Decode: {}", e.to_string()))
          } else {
            image::load_from_memory(&data).map_err(|e| format!("Decode: {}", e.to_string()))
          };
          if let Ok(imgr) = img {
            let (width, height) = (imgr.width() as i32, imgr.height() as i32);
            let thumb = imgr.thumbnail(512, 512);
            if let Some(parent) = thumb_absolute.parent() {
              std::fs::create_dir_all(parent)?;
            }
            thumb.save_with_format(&thumb_absolute, ImageFormat::Jpeg)?;
            let thumb_size = std::fs::metadata(thumb_absolute)?.len() as i64;
            Ok(MediaThumb { width, height, size: thumb_size, duration: None})
          } else {
            Err(anyhow::anyhow!("Image decode error"))
          }
        }).await??;
        Ok(Some(result))
      } else if mime.starts_with("video/") {
        let tmp_dir = std::env::temp_dir();
        let tmp_input = tmp_dir.join(format!("upload_{}.tmp", hash));
        tokio::fs::write(&tmp_input, &data).await?;

        let tmp_input_clone = tmp_input.clone();
        let thumb_absolute_clone = thumb_absolute.clone();

        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<MediaThumb> {
          let output = std::process::Command::new("ffprobe").args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,duration",
            "-of", "json",
            tmp_input_clone.to_str().unwrap()
          ]).output()?;
          let json = serde_json::from_slice::<serde_json::Value>(&output.stdout)?;
          let stream = &json["streams"][0];
          let width = stream["width"].as_i64().unwrap_or(0) as i32;
          let height = stream["height"].as_i64().unwrap_or(0) as i32;
          let duration = stream["duration"].as_str().and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
          let seek_time = if duration >= 1.0 {"00:00:01"} else {"00:00:00"};

          let status = std::process::Command::new("ffmpeg").args([
            "-ss", seek_time,
            "-i", tmp_input_clone.to_str().unwrap(),
            "-vframes", "1",
            "-vf", "scale=512:-1",
            "-y", thumb_absolute_clone.to_str().unwrap()
          ]).status()?;
          if !status.success() {
            return Err(anyhow::anyhow!("FFMPEG video extract error"));
          }

          let thumb_size = std::fs::metadata(&thumb_absolute_clone)?.len() as i64;
          Ok(MediaThumb { width, height, size: thumb_size, duration: Some(duration) })
        }).await??;

        tokio::fs::remove_file(&tmp_input).await?;
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

pub mod database {
  use std::sync::Arc;
  use surrealdb::{Surreal, engine::local::{Db, RocksDb}};

  pub type Database = Arc<Surreal<Db>>;

  pub async fn init(path: &str) -> anyhow::Result<Database> {
    let db = Surreal::new::<RocksDb>(path).await?;
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
      define field if not exists duration on table media type option<float>;
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
    pub duration: Option<f64>,
    pub device_id: Option<String>,
    pub timestamp: DateTime<Utc>
  }

  #[derive(Debug, Serialize)]
  pub struct MediaResponse {
    pub id: String,
    pub hash: String,
    pub extension: String,
    pub mimetype: String,
    pub size: [i64; 2],
    pub duration: Option<f64>,
    pub timestamp: DateTime<Utc>
  }

  impl From<Media> for MediaResponse {
    fn from(v: Media) -> Self {
      let id_str = v.id.as_ref().map(|id| match &id.key {
        RecordIdKey::String(s) => s.clone(),
        other => format!("{:?}", other)
      }).unwrap_or_default();
      Self {
        id: id_str.clone(),
        hash: v.hash,
        extension: v.extension,
        mimetype: v.mimetype,
        size: v.size,
        duration: v.duration,
        timestamp: v.timestamp
      }
    }
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

  impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
      let (code, message) = match self {
        AppError::Internal(x) => (StatusCode::INTERNAL_SERVER_ERROR, x),
        AppError::BadRequest(x) => (StatusCode::BAD_REQUEST, x),
        AppError::NotFound => (StatusCode::NOT_FOUND, "Not Found".into())
      };
      (code, Json(json!({"error": message}))).into_response()
    }
  }
}
