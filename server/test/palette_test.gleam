import dh_server/palette

pub fn loads_shipped_palette_test() {
  let assert Ok(_) = palette.load("colors.json")
}

pub fn default_matches_shipped_file_test() {
  let assert Ok(loaded) = palette.load("colors.json")
  assert loaded == palette.default()
}

pub fn sixteen_entries_test() {
  assert palette.count(palette.default()) == 16
}
