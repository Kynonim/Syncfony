use std::sync::Arc;
use axum::{Router, extract::DefaultBodyLimit};
use syncfony::{database, routes, storage};
use tower_http::cors::CorsLayer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  dotenvy::dotenv().ok();
  ffmpeg_sidecar::download::auto_download().expect("Gagal mengunduh FFMPEG");
  tracing_subscriber::fmt().init();

  let bind = std::env::var("SERVER_BIND_URL").unwrap_or_else(|_| "0.0.0.0:2026".into());
  let storage_url = std::env::var("STORAGE_PATH").unwrap_or_else(|_| "./data/storages".into());
  let database_url = std::env::var("DATABASE_PATH").unwrap_or_else(|_| "./data/dblock".into());

  std::fs::create_dir_all("./data")?;

  let db = database::init(&database_url).await?;
  let storage = Arc::new(storage::Storage::new(storage_url));
  storage.init().await?;

  let state = routes::AppState { db, storage };

  let app = Router::new()
    .merge(routes::router(state))
    .layer(CorsLayer::permissive())
    .layer(DefaultBodyLimit::disable());

  let listener = tokio::net::TcpListener::bind(&bind).await?;
  tracing::info!("Listening on {}", bind);
  axum::serve(listener, app).await?;
  Ok(())
}
