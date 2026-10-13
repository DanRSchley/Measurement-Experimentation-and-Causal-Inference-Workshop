-- xref.lua -- LaTeX-style \ref for the workshop book.
--
-- USAGE   {{< ref ID [style="..."] [text="..."] [link="false"] [class="..."] [suffix="..."] >}}
--
--   ID is any heading id ({#sec-...}) in any chapter, or a part/module label
--   (the `xref:` key in a chapter's front matter).
--
--   style (default "auto"):
--     auto   same module -> "Part 4"; other module -> "Module 2, Part 4"
--            (a section inside a part -> "Title" (Part 4), place dropped if same page)
--     part   "Part 4"            long  "Module 2, Part 4"
--     num    "4"  (for "Parts 2 and 3")      title  "The Exclusion Restriction"
--     full   "Part 4: The Exclusion Restriction"
--   text="..."    override the link text      link="false"  plain text, no hyperlink
--   class="..."   CSS classes on the <a> (e.g. btn btn-primary)    suffix="→"  text appended after a space
--
--   {{< nparts >}}  number of parts in the current module, as a word ("six");  module="2" for another module;
--                   cap="true" capitalises.   {{< nmodules >}}  number of modules.
--
-- NUMBERS ARE NEVER TYPED BY HAND. Module numbers = order of the `part:` entries in
-- _quarto.yml; part numbers = order of chapters inside a module (the first chapter of
-- a module is its intro = "Part 0"). Reorder _quarto.yml and every reference follows.

local registry = nil
local root = nil

local function norm(p) return (p:gsub("\\", "/")) end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if s:sub(1, 3) == "\xEF\xBB\xBF" then s = s:sub(4) end  -- drop a UTF-8 BOM
  return s
end

local function find_root()
  if root then return root end
  local input = norm(quarto.doc.input_file)
  local dir = input:match("^(.*)/[^/]*$") or "."
  while dir and dir ~= "" do
    if exists(dir .. "/_quarto.yml") then root = dir; return root end
    local parent = dir:match("^(.*)/[^/]*$")
    if parent == dir then break end
    dir = parent
  end
  error("xref.lua: could not find _quarto.yml above " .. input)
end

local function str(x) return pandoc.utils.stringify(x) end

local function kw(kwargs, name)
  local v = kwargs[name]
  if v == nil then return nil end
  local s = str(v)
  if s == "" then return nil end
  return s
end

local function strip_md(s)
  s = s:gsub("%*%*", ""):gsub("%*", ""):gsub("`", "")
  s = s:gsub("%[(.-)%]%b()", "%1")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function frontmatter(text)
  local fm = text:match("^%-%-%-%s*\n(.-)\n%-%-%-")
  if not fm then return {} end
  return pandoc.read("---\n" .. fm .. "\n---\n", "markdown").meta
end

local function scan_headings(text)
  local out, in_fence = {}, nil
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence then
      if not in_fence then in_fence = fence
      elseif fence:sub(1, 1) == in_fence:sub(1, 1) then in_fence = nil end
    elseif not in_fence then
      local hashes, rest = line:match("^(#+)%s+(.*)$")
      if hashes then
        local title, attrs = rest:match("^(.*%S)%s+{(#[^{}]*)}%s*$")
        if attrs then
          title = title:gsub("{{<.->}}", "")
          local id = attrs:match("#([%w_%-:%.]+)")
          if id then
            out[#out + 1] = { id = id, level = #hashes, title = strip_md(title) }
          end
        end
      end
    end
  end
  return out
end

local function build_registry()
  if registry then return registry end
  local r = find_root()
  local yml = read_file(r .. "/_quarto.yml")
  local meta = pandoc.read("---\n" .. yml .. "\n---\n", "markdown").meta
  local chapters = meta.book and meta.book.chapters
  registry = { ids = {}, files = {}, modules = {}, nparts = {}, nmodules = 0 }
  if not chapters then return registry end

  local mod_no = 0
  local function add_file(file, m, p, mtitle)
    local text = read_file(r .. "/" .. file)
    if not text then
      quarto.log.warning("xref.lua: chapter not found: " .. file)
      return
    end
    local fm = frontmatter(text)
    local heads = scan_headings(text)
    local primary = {}
    if fm.xref then primary[str(fm.xref)] = true end
    for _, h in ipairs(heads) do
      if h.level == 1 then primary[h.id] = true; break end
    end
    if next(primary) == nil and heads[1] then primary[heads[1].id] = true end
    local info = {
      file = file, module = m, part = p, mtitle = mtitle,
      title = fm.title and str(fm.title) or file,
      html = file:gsub("%.qmd$", ".html"),
    }
    registry.files[file] = info
    if fm.xref then
      registry.ids[str(fm.xref)] = { info = info, is_primary = true }
    end
    for _, h in ipairs(heads) do
      if registry.ids[h.id] and registry.ids[h.id].info ~= info then
        quarto.log.warning("xref.lua: duplicate id '" .. h.id .. "' in " .. file)
      end
      if not registry.ids[h.id] then
        registry.ids[h.id] = { info = info, heading = h, is_primary = primary[h.id] or false }
      end
    end
  end

  for _, item in ipairs(chapters) do
    if type(item) == "table" and item.part then
      mod_no = mod_no + 1
      local mtitle = str(item.part):gsub("^%s*Module%s+%d+%s*:%s*", "")
      registry.modules[mod_no] = mtitle
      local p = -1
      for _, ch in ipairs(item.chapters or {}) do
        p = p + 1
        add_file(str(ch), mod_no, p, mtitle)
      end
      registry.nparts[mod_no] = math.max(p, 0)
    else
      add_file(str(item), 0, 0, "")
    end
  end
  registry.nmodules = mod_no
  return registry
end

local function current_location()
  local r = find_root()
  local input = norm(quarto.doc.input_file)
  local rel = input:sub(#r + 2)
  return rel, (rel:match("^(.*)/[^/]*$") or "")
end

local function rel_url(from_dir, to_path)
  local from, to = {}, {}
  for seg in from_dir:gmatch("[^/]+") do from[#from + 1] = seg end
  for seg in to_path:gmatch("[^/]+") do to[#to + 1] = seg end
  local i = 1
  while i <= #from and i < #to and from[i] == to[i] do i = i + 1 end
  local parts = {}
  for _ = i, #from do parts[#parts + 1] = ".." end
  for j = i, #to do parts[#parts + 1] = to[j] end
  return table.concat(parts, "/")
end

local function strip_prefix(t)
  t = t:gsub("^%s*Part%s+%d+%s*:%s*", "")
  t = t:gsub("^%s*Module%s+%d+%s*:%s*", "")
  return t
end

local function bad(id, why)
  quarto.log.warning("xref.lua: {{< ref " .. tostring(id) .. " >}} -- " .. why)
  return pandoc.Strong({ pandoc.Str("[?? ref " .. tostring(id) .. "]") })
end

local function ref(args, kwargs, meta)
  local id = args[1] and str(args[1]) or nil
  if not id or id == "" then return bad("", "no id given") end
  local reg = build_registry()
  local target = reg.ids[id]
  if not target then return bad(id, "no heading with that id in any chapter") end

  local info = target.info
  local style = kw(kwargs, "style") or "auto"
  local cur_file, cur_dir = current_location()
  local cur_info = reg.files[cur_file]
  local same_module = cur_info and cur_info.module == info.module and info.module > 0
  local same_file = (cur_file == info.file)

  local is_module = (info.part == 0 and info.module > 0)
  local mtxt = "Module " .. info.module
  local ptxt = "Part " .. info.part
  local short = is_module and mtxt or (info.module > 0 and ptxt or info.title)
  local long = is_module and mtxt or (info.module > 0 and (mtxt .. ", " .. ptxt) or info.title)
  local num = is_module and tostring(info.module) or tostring(info.part)

  local label
  if target.is_primary then
    local title = is_module and info.mtitle or strip_prefix(info.title)
    local full = (is_module and mtxt or ptxt) .. ": " .. title
    if style == "part" then label = short
    elseif style == "long" then label = long
    elseif style == "num" then label = num
    elseif style == "title" then label = title
    elseif style == "full" then label = full
    else label = same_module and short or long end
  else
    local h = "\u{201C}" .. target.heading.title .. "\u{201D}"
    local place = same_module and short or long
    if style == "part" then label = short
    elseif style == "long" then label = long
    elseif style == "num" then label = num
    elseif style == "title" then label = h
    elseif style == "full" then label = h .. " (" .. place .. ")"
    else label = same_file and h or (h .. " (" .. place .. ")") end
  end
  local suffix = kw(kwargs, "suffix")  -- the parser trims spaces, so we add one
  label = (kw(kwargs, "text") or label) .. (suffix and (" " .. suffix) or "")

  if kw(kwargs, "link") == "false" then
    return pandoc.Inlines(label)
  end
  local url = rel_url(cur_dir, info.html)
  if not target.is_primary then url = url .. "#" .. id end
  local classes = { "xref-link" }  -- not "quarto-xref": that class triggers Quarto's hover preview popups
  for c in (kw(kwargs, "class") or ""):gmatch("%S+") do classes[#classes + 1] = c end
  return pandoc.Link(pandoc.Inlines(label), url, "", pandoc.Attr("", classes))
end

local WORDS = { [0] = "zero", "one", "two", "three", "four", "five", "six", "seven",
                "eight", "nine", "ten", "eleven", "twelve" }
local function as_word(n, kwargs)
  local w = WORDS[n] or tostring(n)
  if kw(kwargs, "cap") == "true" then w = w:sub(1, 1):upper() .. w:sub(2) end
  return pandoc.Str(w)
end

local function nparts(args, kwargs, meta)
  local reg = build_registry()
  local m = tonumber(kw(kwargs, "module") or (args[1] and str(args[1])) or "")
  if not m then
    local cur = reg.files[(current_location())]
    m = cur and cur.module or 0
  end
  return as_word(reg.nparts[m] or 0, kwargs)
end

local function nmodules(args, kwargs, meta)
  return as_word(build_registry().nmodules, kwargs)
end

return { ["ref"] = ref, ["nparts"] = nparts, ["nmodules"] = nmodules }
