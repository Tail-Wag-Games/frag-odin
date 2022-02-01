package config

Config :: struct {
  app_name: string,
  app_title: string,
  plugin_path: string,
  cache_path: string,
  cwd: string,
  app_version: u32,
  plugins: [dynamic]string,
  window_width: int,
  window_height: int,
}