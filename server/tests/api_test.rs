use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

use syncfony::{database, routes, storage};

static TEST_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

/// PNG 1x1 transparan yang valid, dipakai sebagai payload upload.
const PNG_1X1: &str = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489\
0000000a49444154789c6360000002000100ffff03000006000557bfabd40000000049454e44ae426082";

fn png_bytes() -> Vec<u8> {
  hex::decode(PNG_1X1.replace('\n', "")).expect("PNG hex valid")
}

async fn test_router(token: Option<&str>) -> axum::Router {
  // Kombinasi pid + timestamp + counter memastikan setiap test punya database
  // sendiri, termasuk saat test berjalan paralel di CI.
  let unique = format!(
    "syncfony-test-{}-{}-{}",
    std::process::id(),
    SystemTime::now()
      .duration_since(UNIX_EPOCH)
      .expect("clock")
      .as_nanos(),
    TEST_DIR_COUNTER.fetch_add(1, Ordering::Relaxed),
  );
  let root = std::env::temp_dir().join(unique);
  std::fs::create_dir_all(&root).expect("temp dir");

  let db_path = root.join("db");
  let db = database::init(db_path.to_str().expect("utf8 path"))
    .await
    .expect("database init");

  let storage = Arc::new(storage::Storage::new(root.join("storage")));
  storage.init().await.expect("storage init");

  routes::router(routes::AppState {
    db,
    storage,
    auth_token: token.map(|value| value.to_string()),
  })
}

fn multipart_body(boundary: &str, filename: &str, content_type: &str, data: &[u8]) -> Vec<u8> {
  let mut body = Vec::new();
  body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
  body.extend_from_slice(
    format!("Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n").as_bytes(),
  );
  body.extend_from_slice(format!("Content-Type: {content_type}\r\n\r\n").as_bytes());
  body.extend_from_slice(data);
  body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
  body
}

async fn upload(app: &axum::Router, data: &[u8], token: Option<&str>) -> (StatusCode, String) {
  let boundary = "syncfonyboundary";
  let body = multipart_body(boundary, "photo.png", "image/png", data);

  let mut request = Request::builder()
    .method("POST")
    .uri("/api/upload")
    .header("content-type", format!("multipart/form-data; boundary={boundary}"))
    .body(Body::from(body))
    .expect("request");

  if let Some(token) = token {
    request
      .headers_mut()
      .insert("authorization", format!("Bearer {token}").parse().expect("header"));
  }

  let response = app.clone().oneshot(request).await.expect("upload response");
  let status = response.status();
  let bytes = response.into_body().collect().await.expect("body").to_bytes();
  (status, String::from_utf8_lossy(&bytes).to_string())
}

#[tokio::test]
async fn health_endpoint_returns_marker() {
  let app = test_router(None).await;
  let response = app
    .oneshot(Request::builder().uri("/api/health").body(Body::empty()).unwrap())
    .await
    .expect("response");

  assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn upload_dedupes_by_hash_and_lists_assets() {
  let app = test_router(None).await;
  let data = png_bytes();

  let (status, body) = upload(&app, &data, None).await;
  assert_eq!(status, StatusCode::OK, "upload pertama harus sukses: {body}");
  assert!(body.contains("\"deduplicated\":false"), "{body}");

  let (status, body) = upload(&app, &data, None).await;
  assert_eq!(status, StatusCode::OK);
  assert!(
    body.contains("\"deduplicated\":true"),
    "file identik tidak boleh disimpan dua kali: {body}"
  );

  let response = app
    .clone()
    .oneshot(Request::builder().uri("/api/assets").body(Body::empty()).unwrap())
    .await
    .expect("list response");
  assert_eq!(response.status(), StatusCode::OK);
  let bytes = response.into_body().collect().await.expect("body").to_bytes();
  let text = String::from_utf8_lossy(&bytes);
  assert!(text.contains("\"items\""), "{text}");
  assert_eq!(text.matches("\"hash\"").count(), 1, "hanya satu aset tersimpan: {text}");
}

#[tokio::test]
async fn delete_removes_asset() {
  let app = test_router(None).await;
  let data = png_bytes();

  let (status, body) = upload(&app, &data, None).await;
  assert_eq!(status, StatusCode::OK, "{body}");

  let id = body
    .split("\"id\":\"")
    .nth(1)
    .and_then(|rest| rest.split('"').next())
    .expect("id pada respons upload")
    .to_string();

  let response = app
    .clone()
    .oneshot(
      Request::builder()
        .method("DELETE")
        .uri(format!("/api/assets/{id}"))
        .body(Body::empty())
        .unwrap(),
    )
    .await
    .expect("delete response");
  assert_eq!(response.status(), StatusCode::NO_CONTENT);

  let response = app
    .oneshot(Request::builder().uri("/api/assets").body(Body::empty()).unwrap())
    .await
    .expect("list response");
  let bytes = response.into_body().collect().await.expect("body").to_bytes();
  let text = String::from_utf8_lossy(&bytes);
  assert!(!text.contains("\"hash\""), "aset harus terhapus: {text}");
}

#[tokio::test]
async fn token_is_required_for_write_endpoints() {
  let app = test_router(Some("rahasia")).await;
  let data = png_bytes();

  let (status, _) = upload(&app, &data, None).await;
  assert_eq!(status, StatusCode::UNAUTHORIZED);

  let (status, body) = upload(&app, &data, Some("rahasia")).await;
  assert_eq!(status, StatusCode::OK, "{body}");
}
