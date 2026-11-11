use std::net::SocketAddr;

use saphire_server::{app, db, music, staticfiles};

#[tokio::main]
async fn main() {
    // .env is a development convenience; a missing file is not an error.
    dotenvy::dotenv().ok();

    let database = match db::open_db().await {
        Ok(database) => database,
        Err(error) => {
            eprintln!("database: {error}");
            std::process::exit(1);
        }
    };

    // The shared music library folder, created here so uploads always have a place to go.
    // Every user's songs land in the same folder.
    let library = match music::open_library() {
        Ok(library) => library,
        Err(error) => {
            eprintln!("library: {error}");
            std::process::exit(1);
        }
    };

    let port = match std::env::var("PORT") {
        Ok(port) if !port.is_empty() => port,
        _ => "8080".to_string(),
    };

    let router = app::app(&database, &library, staticfiles::STATIC_DIR, &app::default_limiters());

    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", port.parse::<u16>().unwrap_or(8080))).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("listen: {error}");
            std::process::exit(1);
        }
    };

    println!("Listening on port {port}");

    // `ConnectInfo` is what a per-IP bucket needs: without it every request would share one
    // bucket.
    if let Err(error) = axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>()).await {
        eprintln!("server: {error}");
        std::process::exit(1);
    }
}
