use std::sync::Arc;
use axum::{Router, extract::DefaultBodyLimit, http::{HeaderValue, Method, header}};
use syncfony::{database, routes, storage};
use tower_http::cors::{AllowOrigin, CorsLayer};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  dotenvy::dotenv().ok();
  ffmpeg_sidecar::download::auto_download().expect("Gagal mengunduh FFMPEG");
  tracing_subscriber::fmt().compact().init();

  let bind = std::env::var("SERVER_BIND_URL").unwrap_or_else(|_| "0.0.0.0:2026".into());
  let storage_url = std::env::var("STORAGE_PATH").unwrap_or_else(|_| "./data/storages".into());
  let database_url = std::env::var("DATABASE_PATH").unwrap_or_else(|_| "./data/dblock".into());
  let auth_token = std::env::var("SYNCFONY_TOKEN").ok().filter(|s| !s.trim().is_empty());
  let max_upload_mb: u64 = std::env::var("MAX_UPLOAD_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(2048);
  let cors_origins = std::env::var("CORS_ALLOWED_ORIGINS").ok();

  std::fs::create_dir_all("./data")?;

  let db = database::init(&database_url).await?;
  let storage = Arc::new(storage::Storage::new(storage_url));
  storage.init().await?;

  let state = routes::AppState { db, storage, auth_token };

  let mut app = Router::new()
    .merge(routes::router(state))
    .layer(DefaultBodyLimit::max((max_upload_mb * 1024 * 1024) as usize));

  // CORS tidak aktif secara default (client mobile tidak membutuhkannya).
  // Set CORS_ALLOWED_ORIGINS="*" untuk permisif, atau daftar origin dipisah koma.
  match cors_origins.as_deref().map(str::trim) {
    Some("*") => {
      app = app.layer(CorsLayer::permissive());
      tracing::info!("CORS: permisif (semua origin)");
    }
    Some(list) if !list.is_empty() => {
      let origins: Vec<HeaderValue> = list
        .split(',')
        .filter_map(|origin| origin.trim().parse::<HeaderValue>().ok())
        .collect();
      if !origins.is_empty() {
        tracing::info!("CORS: {} origin diizinkan", origins.len());
        app = app.layer(
          CorsLayer::new()
            .allow_origin(AllowOrigin::list(origins))
            .allow_methods([Method::GET, Method::POST, Method::DELETE, Method::OPTIONS])
            .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE, header::RANGE, header::ACCEPT])
        );
      }
    }
    _ => {}
  }

  let listener = tokio::net::TcpListener::bind(&bind).await?;
  tracing::info!("Listening on {}", bind);
  axum::serve(listener, app).await?;
  Ok(())
}
