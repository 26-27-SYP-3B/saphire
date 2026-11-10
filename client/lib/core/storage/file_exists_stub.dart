/// A browser has no file paths: a local song there was picked as bytes, so nothing can
/// go missing behind a path. The player reads the bytes it was given.
bool fileExists(String path) => false;
