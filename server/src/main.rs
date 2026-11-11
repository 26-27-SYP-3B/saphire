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

    // The port is read once and must be a number: a value that cannot be bound is reported as
    // the value that was given, not quietly replaced, because the line below prints what the
    // server actually listens on.
    let port = match std::env::var("PORT") {
        Ok(port) if !port.is_empty() => match port.parse::<u16>() {
            Ok(port) => port,
            Err(_) => {
                eprintln!("port: {port} is not a port number");
                std::process::exit(1);
            }
        },
        _ => 8080,
    };

    let router = app::app(&database, &library, staticfiles::STATIC_DIR, &app::default_limiters());

    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
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
