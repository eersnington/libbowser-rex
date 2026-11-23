-- Browser panes in Rex. Load this from your init.lua:
--
--   dofile(os.getenv("HOME") .. "/Development/libbowser/rex/browser.lua")
--
-- ⇧⌘B, or "New Browser Pane" in Rex's command list, asks for an address and
-- opens a browser pane beside the focused pane. From a shell:
--
--   rex do browser url=news.ycombinator.com

rex.action{
  name = "browser",
  title = "New Browser Pane",
  args = { url = "string?" },
  run = function(ctx, args)
    local url = args.url
    if url == nil then
      url = rex.ui.input{ title = "New Browser Pane", placeholder = "Search or enter website name" }
    end
    url = url and url:match("^%s*(.-)%s*$")
    if url == nil or url == "" then return end
    return rex.call("session.new_split", {
      session_id = ctx.session_id,
      anchor_id = ctx.block_id,
      direction = "horizontal",
      side = "after",
      focus = true,
      layout = { block = { flavor = "dev.libbowser.browser", options = { url = url } } },
    })
  end,
}

rex.bind("cmd+shift+b", "browser")
