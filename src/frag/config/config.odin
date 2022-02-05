package config

PLUGIN_UPDATE_INTERVAL :: f32(1.0)
MAX_PLUGINS :: 64

Config :: struct {
  app_name: string,
  app_title: string,
  plugin_path: string,
  cache_path: string,
  cwd: string,
  app_version: u32,

  plugins: [MAX_PLUGINS]string,
  
  window_width: int,
  window_height: int,

  num_job_threads: int,
}