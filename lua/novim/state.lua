-- Shared runtime state for NoVim (singleton via module cache)
return {
  sidebar_win = nil,
  sidebar_buf = nil,
  toc = nil,
  toc_loading = false,
  line_map = {},
  current_url = nil,
  prev_url = nil,
  next_url = nil,
  reader_buf = nil,
}
