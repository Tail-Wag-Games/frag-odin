package asset

import ".."

register_asset_type :: proc "c" (name: string, callbacks: frag.Asset_Callbacks) {

}

@(init)
init_api :: proc() {
  frag.asset_api = frag.Asset_API{
    register_asset_type = register_asset_type,
  }
}

