local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local U = require("miuread.util")
local ShelfProgress = require("miuread.shelf_progress")
local Config = require("miuread.config")
local HomeLayout = require("miuread.home_layout")
local Desktop = require("miuread.desktop_ui")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_widget
local home_generation = 0

local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local RoundedImageContainer = WidgetContainer:extend{width = 1, height = 1, radius = 0, ink_boost = 0}
function RoundedImageContainer:getSize()
    return Geom:new{w = self.width, h = self.height}
end
function RoundedImageContainer:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
    local boost = math.max(0, math.min(.18, tonumber(self.ink_boost) or 0))
    if boost > 0 and bb and type(bb.darkenRect) == "function" then
        -- A light contrast lift keeps pale covers legible on e-ink without
        -- turning dark covers into solid blocks.
        pcall(bb.darkenRect, bb, x, y, self.width, self.height, boost)
    end
    local r = math.max(0, math.min(math.floor(self.radius or 0), math.floor(math.min(self.width, self.height) / 2)))
    if r <= 1 or not bb or type(bb.paintRect) ~= "function" then return end
    -- Mask only the four corner pixels. This keeps the image flush with its
    -- box while giving the cover itself rounded corners, without a padded frame.
    for row = 0, r - 1 do
        local dy = r - row
        local inside = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.max(0, math.floor(r - inside + .5))
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local margin = tonumber(options.margin) or 0
    local inset = border + padding + margin
    return FrameContainer:new{
        bordersize = border,
        radius = options.radius or 0,
        padding = padding,
        margin = margin,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local function background(width, height)
    return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE})
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, hold_callback = nil, _hold_handled = false}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
        HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}},
        HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect(_, ges)
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    local now=os.clock()
    if now<(tonumber(self._miu_tap_block_until) or 0) then return true end
    self._miu_tap_block_until=now+.20
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil, ges) end
    return true
end
function TapBox:onHoldSelect()
    self._hold_handled = self.hold_callback ~= nil
    if self.hold_callback then self.hold_callback(self.dimen and self.dimen:copy() or nil) end
    return self.hold_callback ~= nil
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        self._miu_tap_block_until = os.clock() + .20
        return true
    end
    return false
end
function TapBox:handleEvent(event)
    -- Child cards only own taps. Let swipes reach HomeWidget first so the
    -- quick panel and shelf paging are not consumed by KOReader underneath.
    return InputContainer.handleEvent(self, event)
end

local function tappable(width, height, child, callback, hold_callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local function text_button(text, width, height, callback, options)
    options = options or {}
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = options.borderless and 0 or UiScale.line("thin"),
        padding = UiScale.dp(3, 2, 6),
        background = Blitbuffer.COLOR_WHITE,
    }, TextWidget:new{
        text = tostring(text or ""),
        face = face(options.font or "smallinfofont", options.size or 12, options.maximum or 16),
        bold = options.bold ~= false,
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    }), callback)
end

local function image_widget(path, width, height, ink_boost)
    if not path or path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            -- Stretch into the cover box. Book covers are already close to the
            -- target ratio, and this avoids the visible inner blank frame that
            -- scale-to-fit produced on Kindle.
            scale_factor = nil,
            -- Always use MuPDF scaling for covers. Legacy scaling is faster on
            -- a few old devices but visibly softer at small e-ink sizes.
            use_legacy_image_scaling = false,
            file_do_cache = true,
        }
        image:getSize()
    end)
    if ok and image then
        return RoundedImageContainer:new{
            width = width,
            height = height,
            radius = UiScale.radius(7, 5, 13),
            ink_boost = tonumber(ink_boost) or .08,
            image,
        }
    end
    if image and image.free then pcall(image.free, image) end
    return nil
end

local function placeholder(width, height, title, author)
    title = U.trim(tostring(title or "未命名"))
    author = U.trim(tostring(author or ""))
    if title == "" then title = "未命名" end
    local pad = UiScale.dp(3, 2, 5)
    local content_w = math.max(1, width - pad * 2)
    local content_h = math.max(1, height - pad * 2)
    local title_h = math.max(1, math.floor(content_h * (author ~= "" and .58 or .78)))
    local author_h = math.max(1, content_h - title_h)
    local body = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = U.utf8_truncate(title, 24, "…"),
            face = face("cfont", 10.8, 15.5), bold = true,
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = title_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    if author ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = U.utf8_truncate(author, 18, "…"),
            face = face("smallinfofont", 7.8, 10.8),
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = author_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    return fixed_frame(width, height, {
        bordersize = UiScale.line("thin"),
        radius = UiScale.radius(6, 4, 12),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, body)
end

local function solid_bar(width, height, color)
    return fixed_frame(width, height, {background = color or Blitbuffer.COLOR_BLACK})
end

local function progress_bar(width, height, progress)
    progress = math.max(0, math.min(1, tonumber(progress) or 0))
    local filled = math.floor(width * progress + .5)
    local rest = math.max(0, width - filled)
    local row = HorizontalGroup:new{align = "center"}
    if filled > 0 then table.insert(row, solid_bar(filled, height, Blitbuffer.COLOR_BLACK)) end
    if rest > 0 then table.insert(row, solid_bar(rest, height, Blitbuffer.COLOR_GRAY)) end
    return row
end


local function notice_strip(item, width, height)
    local pad = UiScale.dp(6, 5, 10)
    local progress_w = item.progress and math.max(92, math.floor(width * .20)) or 0
    local detail_w = math.max(1, width - progress_w - pad * 3)
    local text = tostring(item.title or "")
    if item.detail and tostring(item.detail) ~= "" then
        text = text .. "　" .. tostring(item.detail)
    end
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = detail_w, h = height - pad * 2}, TextBoxWidget:new{
            text = text,
            face = face("smallinfofont", 10.5, 15),
            bold = true,
            width = detail_w,
            height = height - pad * 2,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }},
    }
    if progress_w > 0 then
        table.insert(row, HorizontalSpan:new{width = pad})
        table.insert(row, progress_bar(progress_w, UiScale.dp(3, 2, 5), item.progress))
    end
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = item.important == true and UiScale.line("thick") or UiScale.line("thin"),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, row), item.on_tap)
end


-- Every mutable label owns a fixed, single-line slot so long names cannot
-- change neighbouring geometry during partial refreshes.
local function single_line(text, width, height, text_face, options)
    options = options or {}
    return Ui.align(TextWidget:new{
        text = tostring(text or ""), face = text_face,
        bold = options.bold == true, fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
        max_width = math.max(1, width), truncate_with_ellipsis = true,
    }, width, height, options.halign or "left")
end

local function hero_source(book)
    local source = tostring(book.unified_source or book.external_source or book.source or "")
    if source == "local" or book.local_file == true then return "本地书籍" end
    if source == "fanqie" then return "番茄小说" end
    if source == "zlibrary" or source == "z-lib" then return "Z-Library" end
    if source == "wechat_mp" or source == "wechat_mp_article" or source == "mp" or source == "mp_article" then return "公众号" end
    return "微信读书"
end

local function hero_card(book, width, height, callback, compact, hold_callback)
    local border = UiScale.line("thin")
    local pad = math.max(border + 1, math.floor(height * .055))
    local inner_w, inner_h = width - (pad + border) * 2, height - (pad + border) * 2
    local cover_h = inner_h
    local cover_w = math.floor(cover_h * .68)
    local gap = math.floor(width * .035)
    local text_w = math.max(1, inner_w - cover_w - gap)
    local label_h = math.floor(inner_h * .13)
    local label_w = math.min(text_w, UiScale.dp(82, 72, 110))
    local body = OverlapGroup:new{dimen = Geom:new{w = inner_w, h = inner_h}, allow_mirroring = false}
    body[#body + 1] = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .05)
        or placeholder(cover_w, cover_h, book.title, book.author)
    local function add(y, widget, offset)
        body[#body + 1] = OffsetContainer:new{x_off = cover_w + gap + (offset or 0), y_off = y, widget}
    end
    add(0, fixed_frame(label_w, label_h, {bordersize = border, background = Blitbuffer.COLOR_WHITE},
        single_line(hero_source(book), label_w - border * 4, label_h - border * 2,
            face("smallinfofont", 9.3, 13), {halign = "center"})))
    local title_y = math.floor(inner_h * .16)
    local title_h = math.floor(inner_h * .31)
    add(title_y, TextBoxWidget:new{
        text = tostring(book.title or "未命名"), face = face("cfont", compact and 18 or 20, 27),
        bold = true, width = text_w, height = title_h, height_adjust = false,
        height_overflow_show_ellipsis = true, alignment = "left",
    })
    add(math.floor(inner_h * .46), single_line(book.author, text_w, math.floor(inner_h * .14), face("cfont", 12, 16)))
    local progress_y = math.floor(inner_h * .64)
    local progress_h = math.max(4, math.floor(inner_h * .024))
    local progress_label_w = math.min(math.floor(text_w * .29), UiScale.dp(110, 90, 150))
    local progress_w = math.max(1, text_w - progress_label_w - gap / 2)
    local progress_known = book.progress_known ~= false and tonumber(book.progress) ~= nil
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    add(progress_y, progress_bar(math.floor(progress_w), progress_h, progress / 100))
    add(progress_y - math.floor(inner_h * .05),
        single_line(ShelfProgress.is_finished(book) and "已读完" or (progress_known and ("已读 " .. math.floor(progress + .5) .. "%") or "进度未知"),
            progress_label_w, math.floor(inner_h * .13), face("smallinfofont", 9.5, 13), {halign = "right"}),
        text_w - progress_label_w)
    local button_h = math.floor(inner_h * .21)
    local button_w = math.min(math.floor(text_w * .40), UiScale.dp(155, 120, 200))
    local recent_w = math.max(1, text_w - button_w - gap / 2)
    local recent = U.trim(tostring(book.last_read_text or ""))
    if recent == "" then recent = "点击继续上次阅读" end
    add(inner_h - button_h, single_line(recent, recent_w, button_h, face("smallinfofont", 9.5, 13)))
    add(inner_h - button_h, tappable(button_w, button_h,
        fixed_frame(button_w, button_h, {background = Blitbuffer.COLOR_BLACK, radius = UiScale.radius(4, 3, 6)},
            single_line("继续阅读  ›", button_w - border * 4, button_h, face("cfont", 12, 17),
                {bold = true, fgcolor = Blitbuffer.COLOR_WHITE, halign = "center"})), callback), text_w - button_w)
    return tappable(width, height, fixed_frame(width, height,
        {bordersize = border, padding = pad, radius = UiScale.radius(4, 3, 6), background = Blitbuffer.COLOR_WHITE}, body),
        callback, function(anchor) if hold_callback then hold_callback(book, anchor) end end)
end

local function welcome_card(width, height, callback)
    local inset = math.max(1, UiScale.dp(2, 2, 3))
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = OffsetContainer:new{
        x_off = inset, y_off = inset,
        fixed_frame(math.max(1, width - inset * 2), math.max(1, height - inset * 2), {
            bordersize = math.max(UiScale.line("thin"), 1),
            radius = UiScale.radius(9, 6, 15),
            background = Blitbuffer.COLOR_WHITE,
        }, VerticalGroup:new{
            align = "center",
            TextWidget:new{text = "开始阅读", face = UiScale.iconFace("cfont", 18, 24), bold = true},
            VerticalSpan:new{height = UiScale.dp(7, 5, 10)},
            TextWidget:new{
                text = "从书架选择一本内容",
                face = face("smallinfofont", 11, 14),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }),
    }
    return tappable(width, height, layers, callback)
end

local function shelf_folder_card(folder, width, height, callback)
    -- A folder occupies exactly one normal book slot.  Its visual body uses the
    -- same cover geometry as a book, so mixed folders/books stay on one grid.
    local pad = math.max(UiScale.dp(1, 0, 2), math.floor(width * .004))
    local inner_w = math.max(1, width - pad * 2)
    local title_h = math.max(UiScale.dp(29, 25, 40), math.min(UiScale.dp(39, 32, 47), math.floor(height * .155)))
    local vgap = UiScale.dp(2, 2, 4)
    local cover_h = math.max(UiScale.dp(78, 64, 108), height - title_h - vgap)
    local cover_w = math.max(UiScale.dp(54, 46, 78), math.min(math.floor(inner_w * .995), math.floor(cover_h * .715)))
    local icon_key = folder.local_parent==true and "back" or "folder"
    local icon_size = math.max(UiScale.dp(36, 31, 52), math.min(math.floor(cover_w * .58), math.floor(cover_h * .35)))
    local cover_inset = UiScale.line("thin") + UiScale.dp(2, 1, 4)
    local icon_area_w = math.max(1, cover_w - cover_inset * 2)
    local icon_area_h = math.max(1, cover_h - cover_inset * 2)
    local cover = fixed_frame(cover_w, cover_h, {
        bordersize = UiScale.line("thin"),
        radius = UiScale.radius(7, 5, 12),
        padding = UiScale.dp(2, 1, 4),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, Ui.icon(icon_key, icon_area_w, icon_area_h, icon_size, {
        face = UiScale.iconFace("cfont", 28, 40),
    }))
    local body = VerticalGroup:new{
        align = "center",
        cover,
        VerticalSpan:new{height = vgap},
        TextBoxWidget:new{
            text = tostring(folder.title or "文件夹"), face = face("cfont", 11.8, 16.5), bold = true,
            width = inner_w, height = title_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    return tappable(width, height, CenterContainer:new{dimen = Geom:new{w = width, h = height}, body}, function(anchor)
        if callback then callback(folder, anchor) end
    end)
end


local function shelf_cover_geometry(width, height)
    local gap = UiScale.dp(2, 1, 4)
    local title_h = math.max(UiScale.dp(24, 20, 31), math.floor(height * .115))
    local status_h = math.max(UiScale.dp(18, 15, 24), math.floor(height * .085))
    local cover_h = math.max(1, height - title_h - status_h - gap * 2)
    local cover_w = math.max(1, math.min(math.floor(width * .82), math.floor(cover_h * .68)))
    return cover_w, cover_h, title_h, status_h, gap
end

local function shelf_cover_target_size(width, height, oversample)
    local cover_w, cover_h = shelf_cover_geometry(width, height)
    local scale = math.max(1, math.min(1.25, tonumber(oversample) or 1.12))
    return math.max(1, math.floor(cover_w * scale + .5)), math.max(1, math.floor(cover_h * scale + .5))
end

local function shelf_book_card(book, width, height, callback, hold_callback)
    if book and (book.local_folder == true or book.kind == "folder") then
        return shelf_folder_card(book, width, height, callback)
    end
    local cover_w, cover_h, title_h, status_h, gap = shelf_cover_geometry(width, height)
    local cover = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .06)
        or placeholder(cover_w, cover_h, book.title, book.author)
    local status = U.trim(tostring(book.status_text or ""))
    local progress_known = book.progress_known ~= false and tonumber(book.progress) ~= nil
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local label = "未开始"
    if book.download_active == true then
        label = "下载中 " .. math.floor(math.max(0, math.min(1, tonumber(book.download_progress) or 0)) * 100 + .5) .. "%"
    elseif status == "失败" or status == "待修复" or status == "排队中" or status == "批注待修复" then
        label = status
    elseif ShelfProgress.is_finished(book) then label = "已读完"
    elseif progress_known then label = math.floor(progress + .5) .. "%"
    else label = "进度未知" end
    local body = VerticalGroup:new{align = "left",
        cover, VerticalSpan:new{height = gap},
        single_line(book.title or "未命名", cover_w, title_h, face("cfont", 10.5, 15), {bold = true}),
        VerticalSpan:new{height = gap},
        single_line(label, cover_w, status_h, face("smallinfofont", 8.8, 12)),
    }
    return tappable(width, height, Ui.align(body, width, height, "center", "top"),
        function(anchor, ges) if callback then callback(book, anchor, ges) end end,
        function(anchor) if hold_callback then hold_callback(book, anchor) end end)
end

local function category_tabs(tabs, width, height)
    tabs = tabs or {}
    if #tabs == 0 then return background(width, height) end
    local item_w = math.floor(width / #tabs)
    local row = HorizontalGroup:new{align = "center"}
    for _, tab in ipairs(tabs) do
        local label = tostring(tab.title or "")
        if tonumber(tab.count) then label = label .. " " .. tostring(tab.count) end
        local item = OverlapGroup:new{dimen = Geom:new{w = item_w, h = height}, allow_mirroring = false}
        item[#item + 1] = single_line(label, item_w, height - UiScale.line("thick"),
            face("smallinfofont", 10.4, 14.5), {bold = tab.selected == true})
        if tab.selected then
            item[#item + 1] = OffsetContainer:new{x_off = 0, y_off = height - UiScale.line("thick"),
                solid_bar(math.floor(item_w * .78), UiScale.line("thick"))}
        end
        row[#row + 1] = tappable(item_w, height, item, tab.on_tap)
    end
    return row
end

local function empty_section(width, height, text, callback)
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = 0,
        padding = UiScale.dp(7, 6, 12),
        background = Blitbuffer.COLOR_WHITE,
    }, Ui.textbox(tostring(text or "暂时没有内容"), math.max(1, width - 32),
        math.max(1, height - UiScale.dp(14, 12, 24)), face("smallinfofont", 11, 15), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        })), callback)
end

local HomeWidget = InputContainer:extend{
    name = "miuread_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    header_dimen = nil,
    content_dimen = nil,
    section_dimen = nil,
    _miu_closed = false,
    _quick_panel_pending = false,
}


function HomeWidget:_notify_resume_interaction(kind)
    local callback=self._miu_resume_interaction_callback
    if not callback then return end
    local now=os.clock()
    if now-(tonumber(self._miu_last_interaction_at) or 0)<.06 then return end
    self._miu_last_interaction_at=now
    local first=self._miu_resume_waiting_interaction==true
    self._miu_resume_waiting_interaction=false
    pcall(callback,first,tostring(kind or "input"))
end

function HomeWidget:handleEvent(event)
    -- ReaderUI may keep the already-built home underneath the document during
    -- page transitions. A parked home must be completely inert so its gesture
    -- ranges and child TapBoxes can never compete with the reader.
    if self._miu_input_suspended==true then return true end
    if event and event.handler=="onGesture" then
        self:_notify_resume_interaction("gesture")
        local ges=event.args and event.args[1]
        local direction=ges and ges.direction
        local gesture=ges and ges.ges
        local pos=ges and (ges.start_pos or ges.pos)
        local shelf_owned=(direction=="west" or direction=="east") and pos and self.section_dimen
            and pos.x>=self.section_dimen.x and pos.x<=self.section_dimen.x+self.section_dimen.w
            and pos.y>=self.section_dimen.y and pos.y<=self.section_dimen.y+self.section_dimen.h
        local top_owned=direction=="south" and pos and self.top_swipe_dimen
            and pos.x>=self.top_swipe_dimen.x and pos.x<=self.top_swipe_dimen.x+self.top_swipe_dimen.w
            and pos.y>=self.top_swipe_dimen.y and pos.y<=self.top_swipe_dimen.y+self.top_swipe_dimen.h
        if top_owned and (gesture == "swipe" or gesture == "pan_release")
            and self:_open_quick_panel_from_gesture(ges) then
            return true
        end
        local pointer_action=gesture=="tap" or gesture=="hold" or gesture=="hold_release"
            or gesture=="double_tap" or gesture=="two_finger_tap"

        -- Visible MiuRead controls get pointer input first. If no child consumes
        -- the pointer gesture, hand it to KOReader's configured Gesture Manager
        -- before this fullscreen page stops propagation.
        if pointer_action then
            if self:propagateEvent(event) then return true end
            if GestureBridge.dispatch(ges) then return true end
            return true
        end

        -- Configured edge/corner gestures take priority over the shelf's broad
        -- horizontal swipe area. This keeps left/right edge actions available
        -- without letting ordinary shelf swipes leak through to KOReader.
        if GestureBridge.dispatchEdge and GestureBridge.dispatchEdge(ges) then return true end
        if not shelf_owned and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self,event)
end

function HomeWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function HomeWidget:_metrics()
    local m = HomeLayout.metrics(Screen:getWidth(), Screen:getHeight())
    m.line = UiScale.line("thin")
    return m
end

function HomeWidget:_register_top_swipe(m)
    if not Device:isTouchDevice() then self.ges_events={}; return end
    -- Own only the true status/header strip. The previous 18–26% zone
    -- overlapped the recent-reading card and competed with KOReader gestures,
    -- which made a pull-down feel delayed on Kindle.
    local top_h = math.max(m.header_h + m.margin + m.gap, math.floor(m.sh * .10))
    top_h = math.min(math.floor(m.sh * .14), math.max(top_h, UiScale.dp(82, 72, 118)))
    self.top_swipe_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, top_h)}
    self.ges_events={
        HomeQuickPanelSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeQuickPanelPanRelease={GestureRange:new{
            ges="pan_release",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeShelfSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.section_dimen or self.content_dimen end,
        }},
    }
end

function HomeWidget:_open_quick_panel_from_gesture(ges)
    local direction = ges and ges.direction
    local start = ges and (ges.start_pos or ges.pos)
    local in_top = start and self.top_swipe_dimen
        and start.x >= self.top_swipe_dimen.x and start.x <= self.top_swipe_dimen.x + self.top_swipe_dimen.w
        and start.y >= self.top_swipe_dimen.y and start.y <= self.top_swipe_dimen.y + self.top_swipe_dimen.h
    if direction == "south" and in_top and self.opts and self.opts.on_quick_panel then
        if self._quick_panel_pending then return true end
        self._quick_panel_pending=true
        -- Finish the gesture dispatch before building the panel. This avoids
        -- competing with the underlying Gesture Manager in the same event.
        UIManager:nextTick(function()
            if self._miu_closed then return end
            self._quick_panel_pending=false
            if self.opts and self.opts.on_quick_panel then self.opts.on_quick_panel() end
        end)
        return true
    end
    return false
end
function HomeWidget:onHomeQuickPanelSwipe(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end
function HomeWidget:onHomeQuickPanelPanRelease(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end

function HomeWidget:onHomeShelfSwipe(_,ges)
    if not (ges and self.opts and self.opts.on_shelf_page) then return false end
    if ges.direction=="west" then self.opts.on_shelf_page(1); return true end
    if ges.direction=="east" then self.opts.on_shelf_page(-1); return true end
    return false
end

function HomeWidget:_build_header(children, m)
    local status_h = math.floor(m.header_h * .55)
    local date_h = m.header_h - status_h
    local battery_w = math.floor(m.content_w * .14)
    local icon_w = math.floor(status_h * .90)
    local clock_w = math.floor(m.content_w * .13)
    local bluetooth_w = self.opts.bluetooth_visible == true and icon_w or 0
    local right_w = clock_w + icon_w + bluetooth_w + battery_w
    local clock_x = m.margin + m.content_w - right_w
    local logo_w = math.max(1, clock_x - m.margin - m.gap)
    self:_add(children, m.margin, m.top,
        tappable(logo_w, status_h,
            single_line(self.opts.title or "觅阅", logo_w, status_h, face("cfont", 15, 21), {bold = true}),
            self.opts.on_account))
    local clock = single_line(self.opts.clock_text or "--:--", clock_w, status_h, face("smallinfofont", 10.2, 14), {halign = "right"})
    self:_add(children, clock_x, m.top, clock)
    local status_x = clock_x + clock_w
    self:_add(children, status_x, m.top, tappable(icon_w, status_h,
        Ui.icon("wifi", icon_w, status_h, math.floor(status_h * .55)), self.opts.on_quick_panel))
    status_x = status_x + icon_w
    if bluetooth_w > 0 then
        self:_add(children, status_x, m.top, tappable(icon_w, status_h,
            Ui.icon("bluetooth", icon_w, status_h, math.floor(status_h * .49)), self.opts.on_bluetooth or self.opts.on_quick_panel))
        status_x = status_x + icon_w
    end
    local battery_icon_w = math.floor(battery_w * .40)
    local battery = single_line(self.opts.battery_text or "--%", battery_w - battery_icon_w, status_h,
        face("smallinfofont", 10.2, 14), {halign = "right"})
    self:_add(children, status_x, m.top, tappable(battery_w, status_h,
        HorizontalGroup:new{align = "center", Ui.icon("battery", battery_icon_w, status_h, math.floor(status_h * .55)), battery},
        self.opts.on_quick_panel))
    local date = single_line(self.opts.date_text, m.content_w, date_h, face("smallinfofont", 9.3, 13))
    self:_add(children, m.margin, m.top + status_h, date)
    self._header_text_refs = {battery = battery[1]}
    self._header_field_dimens = {battery = Geom:new{x = status_x, y = m.top, w = battery_w, h = status_h}}
    self._dashboard_text_refs = {clock = clock[1], date = date[1]}
    self._dashboard_field_dimens = {
        clock = Geom:new{x = clock_x, y = m.top, w = clock_w, h = status_h},
        date = Geom:new{x = m.margin, y = m.top + status_h, w = m.content_w, h = date_h},
    }
    self:_add(children, m.margin, m.top + m.header_h, solid_bar(m.content_w, m.line))
end

function HomeWidget:_grid_geometry(m, width, available_h)
    -- Fixed capacity also applies to sparse last pages and folder cards.
    return HomeLayout.grid(m, width, available_h)
end

local function shelf_book_key(book)
    if type(book) ~= "table" then return "" end
    local id = tostring(book.bookId or book.book_id or "")
    if id ~= "" then return id end
    local file = tostring(book.file or "")
    if file ~= "" then return "file:" .. file end
    return ""
end

function HomeWidget:_render_grid(children, m, x, y, width, height, books, on_open, on_hold, force_rows)
    if #books == 0 then return 0 end
    local columns, rows, col_gap, row_gap, card_w, card_h = self:_grid_geometry(m, width, height, #books, force_rows)
    local capacity = columns * rows
    local slot = 0
    for _,book in ipairs(books) do
        local folder=book and (book.local_folder==true or book.kind=="folder")
        if slot>=capacity then break end
        local row = math.floor(slot / columns)
        local col = slot % columns
        local item_w = card_w
        local item_x = x + col * (card_w + col_gap)
        local item_y = y + row * (card_h + row_gap)
        self:_add(children,item_x,item_y,shelf_book_card(book, item_w, card_h, on_open, on_hold))
        if self._building_shelf_slots and not folder then
            local key=shelf_book_key(book)
            if key~="" then
                self._building_shelf_slots[key]={
                    parent=children,index=#children,x=item_x,y=item_y,w=item_w,h=card_h,book=book,
                }
            end
        end
        slot = slot + 1
    end
    return rows * card_h + math.max(0, rows - 1) * row_gap
end

local function page_footer(width, height, page, pages, on_page)
    page = math.max(1, tonumber(page) or 1)
    pages = math.max(1, tonumber(pages) or 1)
    local arrow_w = math.max(UiScale.dp(54, 48, 88), math.floor(width * .18))
    local middle_w = math.max(1, width - arrow_w * 2)
    local row = HorizontalGroup:new{align = "center"}
    table.insert(row, text_button("‹", arrow_w, height, page > 1 and function() on_page(-1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    table.insert(row, CenterContainer:new{dimen = Geom:new{w = middle_w, h = height}, TextWidget:new{
        text = tostring(page) .. " / " .. tostring(pages),
        face = face("smallinfofont", 9, 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }})
    table.insert(row, text_button("›", arrow_w, height, page < pages and function() on_page(1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page < pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    return row
end

local function dashboard_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return hours .. "小时" .. minutes .. "分钟" end
    return minutes .. "分钟"
end

local function reading_summary(opts, width, height)
    -- KOReader's database also counts downloaded WeRead books. Cloud totals
    -- may already include their synced time, so these sources cannot be added.
    local selected, source_label
    for _, source in ipairs({{opts.show_weread_stats, opts.weread_stats, "微信"}, {opts.show_local_stats, opts.local_stats, "本机"}}) do
        local stats = source[2]
        if source[1] ~= false and type(stats) == "table" and stats.available ~= false
            and (tonumber(stats.today_seconds) or tonumber(stats.total_seconds)) then
            selected, source_label = stats, source[3]
            break
        end
    end
    local today = selected and tonumber(selected.today_seconds)
    local week = selected and tonumber(selected.total_seconds)
    local cell_w = math.floor(width * .55)
    local row = HorizontalGroup:new{align = "center",
        single_line((source_label and source_label .. " · " or "") .. "今日 " .. (today and dashboard_duration(today) or "暂无数据"), cell_w, height, face("smallinfofont", 10.5, 15)),
        single_line("本周阅读  " .. (week and dashboard_duration(week) or "暂无数据") .. "  ›", width - cell_w, height, face("smallinfofont", 10.5, 15), {halign = "right"}),
    }
    return tappable(width, height, row, opts.on_stats or opts.on_weread_stats or opts.on_local_stats)
end

function HomeWidget:_build_navigation(children, m)
    local callbacks = {home = self.opts.on_home, library = self.opts.on_library,
        bookstore = self.opts.on_bookstore, tools = self.opts.on_menu}
    self._navigation_targets = Desktop.dock(children, m, "home", function(destination)
        if callbacks[destination] then callbacks[destination]() end
    end)
end

function HomeWidget:_build_sections(children, m, compact, mode)
    local build_static = mode ~= "section"
    local build_section = mode ~= "static"
    local x, y, width = m.margin, m.body_y, m.content_w
    local notice = (self.opts.alerts or {})[1] or self.opts.download_notice
    if notice then
        local notice_h = math.floor(m.stats_h * .8)
        if build_static then self:_add(children, x, y, notice_strip(notice, width, notice_h)) end
        y = y + notice_h + m.gap
    end
    if build_static then
        local hero = self.opts.hero
        self:_add(children, x, y, hero and hero_card(hero, width, m.hero_h, hero.on_tap, compact, self.opts.on_hold_book)
            or welcome_card(width, m.hero_h, self.opts.on_empty_account))
        self._hero_region = Geom:new{x = x, y = y, w = width, h = m.hero_h}
    end
    y = y + m.hero_h + m.gap
    local show_stats = self.opts.show_weread_stats ~= false or self.opts.show_local_stats ~= false
    if build_static then self._summary_slot = nil end
    if show_stats then
        if build_static then
            self:_add(children, x, y, reading_summary(self.opts, width, m.stats_h))
            self._summary_slot = {parent = children, index = #children, x = x, y = y, w = width, h = m.stats_h}
            self:_add(children, x, y + m.stats_h, solid_bar(width, m.line))
        end
        y = y + m.stats_h + m.gap
    end
    self.section_dimen = Geom:new{x = x, y = y, w = width, h = math.max(1, m.nav_y - m.gap - y)}
    if build_static then self:_build_navigation(children, m) end
    if not build_section then return end

    local heading_h = m.shelf_heading_h
    local all_w = math.floor(width * .13)
    local search_w = math.floor(width * .07)
    local filter_w = math.floor(width * .20)
    local title_w = width - all_w - search_w - filter_w
    self:_add(children, x, y, tappable(title_w, heading_h,
        single_line("我的书架" .. (self.opts.on_shelf_source and " ▾" or ""), title_w, heading_h, face("cfont", 16, 23), {bold = true}),
        self.opts.on_shelf_source))
    self:_add(children, x + title_w, y, tappable(filter_w, heading_h,
        single_line(self.opts.shelf_filter_label or "排序", filter_w, heading_h, face("smallinfofont", 9.5, 13), {halign = "right"}),
        self.opts.on_shelf_filter))
    self:_add(children, x + title_w + filter_w, y, tappable(search_w, heading_h,
        Ui.icon("search", search_w, heading_h, math.floor(heading_h * .47)), self.opts.on_search))
    self:_add(children, x + width - all_w, y, tappable(all_w, heading_h,
        single_line("全部 ›", all_w, heading_h, face("smallinfofont", 10, 14), {halign = "right"}), self.opts.on_library))
    y = y + heading_h
    self:_add(children, x, y, category_tabs(self.opts.tabs, width, m.tabs_h))
    y = y + m.tabs_h + m.gap
    local subtabs = self.opts.shelf_subtabs or {}
    if #subtabs > 0 then
        self:_add(children, x, y, category_tabs(subtabs, width, m.tabs_h))
        y = y + m.tabs_h + m.gap
    end
    local bottom = m.nav_y - m.gap
    local grid_h = math.max(1, bottom - y - m.footer_h)
    local books = self.opts.shelf_books or {}
    if #books > 0 then
        self:_render_grid(children, m, x, y, width, grid_h, books, self.opts.on_open_book, self.opts.on_hold_book)
    else
        self:_add(children, x, y, empty_section(width, grid_h, self.opts.empty_text or "从书架选择一本书开始阅读", self.opts.on_library))
    end
    self:_add(children, x, bottom - m.footer_h,
        page_footer(width, m.footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
end

function HomeWidget:_section_cache_id(opts)
    opts=opts or self.opts or {}
    local key=tostring(opts.section_cache_key or "")
    local revision=tostring(opts.section_revision or "")
    if key=="" or revision=="" then return nil end
    return key.."|"..revision
end

function HomeWidget:_clear_inactive_section_cache()
    local cache=self._section_layer_cache
    if type(cache)~="table" then return end
    for _,entry in pairs(cache) do
        local layer=type(entry)=="table" and entry.layer or nil
        if layer and layer~=self._section_layer and layer.free then pcall(layer.free,layer) end
    end
    self._section_layer_cache=nil
    self._section_cache_clock=0
end

function HomeWidget:_remember_section_layer(cache_id,layer,region,slots)
    if not cache_id or not layer then return end
    self._section_layer_cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    -- One logical view keeps only its newest revision. Cover/progress/header
    -- mutations must not accumulate whole rendered Home layers.
    local logical=tostring(cache_id):match("^(.*)|[^|]+$") or tostring(cache_id)
    for id,entry in pairs(self._section_layer_cache) do
        local other=tostring(id):match("^(.*)|[^|]+$") or tostring(id)
        if id~=cache_id and other==logical then
            self._section_layer_cache[id]=nil
            if entry.layer and entry.layer~=self._section_layer and entry.layer.free then pcall(entry.layer.free,entry.layer) end
        end
    end
    self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
    self._section_layer_cache[cache_id]={
        layer=layer,region=region and region:copy() or nil,slots=slots,used=self._section_cache_clock,
    }
    local count=0
    for _ in pairs(self._section_layer_cache) do count=count+1 end
    local max_layers=math.max(1,tonumber(Config.HOME_SECTION_CACHE_LAYERS) or 3)
    while count>max_layers do
        local oldest_id,oldest_entry
        for id,entry in pairs(self._section_layer_cache) do
            if entry.layer~=self._section_layer
                and (not oldest_entry or (tonumber(entry.used) or 0)<(tonumber(oldest_entry.used) or 0)) then
                oldest_id,oldest_entry=id,entry
            end
        end
        if not oldest_id then break end
        self._section_layer_cache[oldest_id]=nil
        if oldest_entry.layer and oldest_entry.layer.free then pcall(oldest_entry.layer.free,oldest_entry.layer) end
        count=count-1
    end
end

function HomeWidget:_rebuild()
    self:_clear_inactive_section_cache()
    UiScale.setDisplayMode(self.opts and self.opts.display_size or "standard")
    local m = self:_metrics()
    self._last_screen_w, self._last_screen_h = m.sw, m.sh
    self._last_rotation = Screen.getRotationMode and Screen:getRotationMode() or nil
    self._metrics_cache = m
    self.dimen = Geom:new{x = 0, y = 0, w = m.sw, h = m.sh}
    self.header_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, m.body_y)}
    self.content_dimen = Geom:new{x = 0, y = m.body_y, w = m.sw, h = math.max(1, m.sh - m.body_y)}
    self.section_dimen = self.content_dimen:copy()
    self:_register_top_swipe(m)
    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    children[#children + 1] = background(m.sw, m.sh)
    self:_build_header(children, m)
    local compact = tostring(self.opts.layout_style or "standard") == "compact"
    local static_body_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(static_body_layer, m, compact, "static")
    children[#children + 1] = static_body_layer
    self._static_body_layer = static_body_layer
    self._static_body_layer_index = #children
    local section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self._building_shelf_slots={}
    self:_build_sections(section_layer, m, compact, "section")
    local section_slots=self._building_shelf_slots
    self._building_shelf_slots=nil
    children[#children + 1] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    self._section_layer_index = #children
    self:_remember_section_layer(self:_section_cache_id(self.opts),section_layer,self.section_dimen,section_slots)
    local previous = self[1]
    self[1] = children
    if previous and previous ~= children and previous.free then pcall(previous.free, previous) end
end

function HomeWidget:_mark_dirty(kind, previous_region)
    local region
    if kind == "section" then region = self.section_dimen
    elseif kind == "header" then region = self.header_dimen
    elseif kind == "content" then region = self.content_dimen
    elseif kind == "page" then region = self.dimen
    else
        UIManager:setDirty(self, "full")
        return
    end
    if previous_region and region then region = previous_region:combine(region)
    else region = region or previous_region end
    if region then
        local safety=UiScale.dp(4,3,7)
        local x=math.max(0,(region.x or 0)-safety)
        local y=math.max(0,(region.y or 0)-safety)
        local right=math.min(Screen:getWidth(),(region.x or 0)+(region.w or 1)+safety)
        local bottom=math.min(Screen:getHeight(),(region.y or 0)+(region.h or 1)+safety)
        region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
        if kind=="section" then
            -- First surface uses the normal UI waveform so tab/source/page
            -- switching is responsive. A coalesced full cleanup runs only after
            -- the user stops switching, preserving final e-ink quality.
            UIManager:setDirty(self,function() return "ui",region end)
            if self._section_clean_refresh_task then UIManager:unschedule(self._section_clean_refresh_task) end
            local clean_region=region:copy()
            local task
            task=function()
                if self._miu_closed or self._section_clean_refresh_task~=task then return end
                self._section_clean_refresh_task=nil
                if self._miu_input_suspended==true or self._miu_device_suspended==true then return end
                UIManager:setDirty(self,function() return "full",clean_region end)
                logger.info("[MiuRead][HomeSwitchPerf] quality cleanup","delay_ms=",tostring(math.floor((tonumber(Config.HOME_SECTION_CLEAN_REFRESH_DELAY) or 2.8)*1000+.5)))
            end
            self._section_clean_refresh_task=task
            UIManager:scheduleIn(math.max(.8,tonumber(Config.HOME_SECTION_CLEAN_REFRESH_DELAY) or 2.8),task)
        else
            UIManager:setDirty(self,function() return "ui",region end)
        end
    else
        UIManager:setDirty(self, "full")
    end
end

function HomeWidget:update(opts, refresh_kind)
    local previous_region
    if refresh_kind == "section" and self.section_dimen then previous_region = self.section_dimen:copy()
    elseif refresh_kind == "header" and self.header_dimen then previous_region = self.header_dimen:copy()
    elseif refresh_kind == "content" and self.content_dimen then previous_region = self.content_dimen:copy()
    elseif refresh_kind == "page" and self.dimen then previous_region = self.dimen:copy() end
    self.opts = opts or self.opts or {}
    if type(self.opts.on_interaction)=="function" then
        self._miu_resume_interaction_callback=self.opts.on_interaction
    end
    self:_rebuild()
    self:_mark_dirty(refresh_kind or "full", previous_region)
    return self
end

function HomeWidget:updateHeader(fields)
    fields = type(fields) == "table" and fields or {}
    if fields.bluetooth_visible ~= nil and (self.opts.bluetooth_visible == true) ~= (fields.bluetooth_visible == true) then
        for key, value in pairs(fields) do self.opts[key] = value end
        return self:update(self.opts, "header")
    end
    -- Names and sync details are available in the quick panel. Their changes
    -- must not rebuild covers or repaint a status bar that only shows icons.
    for _, key in ipairs({"account_name", "wifi_text", "bluetooth_text", "sync_text"}) do
        if fields[key] ~= nil then self.opts[key] = tostring(fields[key]) end
    end
    if fields.battery_text ~= nil and self.opts.battery_text ~= fields.battery_text then
        self.opts.battery_text = tostring(fields.battery_text)
        local ref = self._header_text_refs and self._header_text_refs.battery
        local region = self._header_field_dimens and self._header_field_dimens.battery
        if not ref or not region then return self:update(self.opts, "header") end
        ref:setText(self.opts.battery_text)
        UIManager:setDirty(self, function() return "ui", region end)
    end
    return true
end

function HomeWidget:updateDashboard(fields)
    fields = type(fields) == "table" and fields or {}
    local refs = self._dashboard_text_refs or {}
    local dimens = self._dashboard_field_dimens or {}
    local region
    for key, name in pairs({clock_text = "clock", date_text = "date"}) do
        if fields[key] ~= nil and self.opts[key] ~= fields[key] then
            self.opts[key] = tostring(fields[key])
            if not refs[name] or not dimens[name] then return self:update(self.opts, "page") end
            refs[name]:setText(self.opts[key])
            region = region and region:combine(dimens[name]) or dimens[name]:copy()
        end
    end
    local stats_changed = fields.weread_stats ~= nil or fields.local_stats ~= nil
    for _, key in ipairs({"weread_stats", "local_stats"}) do
        if fields[key] ~= nil then self.opts[key] = fields[key] end
    end
    local slot = self._summary_slot
    if stats_changed and slot then
        local old = slot.parent[slot.index]
        slot.parent[slot.index] = OffsetContainer:new{x_off = slot.x, y_off = slot.y,
            reading_summary(self.opts, slot.w, slot.h)}
        if old and old.free then pcall(old.free, old) end
        local bounds = Geom:new{x = slot.x, y = slot.y, w = slot.w, h = slot.h}
        region = region and region:combine(bounds) or bounds
    end
    if region then UIManager:setDirty(self, function() return "ui", region end) end
    return true
end

function HomeWidget:updateSection(opts)
    local started=os.clock()
    opts = opts or {}
    self.opts.tabs = opts.tabs or self.opts.tabs
    self.opts.shelf_subtabs = opts.shelf_subtabs or {}
    self.opts.shelf_title = opts.shelf_title or self.opts.shelf_title
    self.opts.shelf_books = opts.shelf_books or {}
    self.opts.empty_text = opts.empty_text or self.opts.empty_text
    self.opts.on_open_book = opts.on_open_book or self.opts.on_open_book
    self.opts.on_hold_book = opts.on_hold_book or self.opts.on_hold_book
    self.opts.home_actions = opts.home_actions or self.opts.home_actions
    if opts.on_shelf_all ~= nil then self.opts.on_shelf_all = opts.on_shelf_all end
    if opts.on_shelf_filter ~= nil then self.opts.on_shelf_filter = opts.on_shelf_filter end
    if opts.on_shelf_source ~= nil then self.opts.on_shelf_source = opts.on_shelf_source end
    if opts.shelf_filter_label ~= nil then self.opts.shelf_filter_label = opts.shelf_filter_label end
    self.opts.on_shelf_page = opts.on_shelf_page or self.opts.on_shelf_page
    self.opts.shelf_page = opts.shelf_page or self.opts.shelf_page
    self.opts.shelf_pages = opts.shelf_pages or self.opts.shelf_pages
    self.opts.section_cache_key = opts.section_cache_key or self.opts.section_cache_key
    self.opts.section_revision = opts.section_revision or self.opts.section_revision

    local m = self._metrics_cache
    local root = self[1]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not m or not root or sw ~= self._last_screen_w or sh ~= self._last_screen_h
        or not self._section_layer_index then
        return self:update(self.opts, "section")
    end
    local previous_region = self.section_dimen and self.section_dimen:copy() or nil
    local cache_id=self:_section_cache_id(self.opts)
    local cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    local cached=cache_id and cache[cache_id] or nil
    local section_layer=cached and cached.layer or nil
    local cache_hit=section_layer~=nil
    local section_slots
    if not section_layer then
        section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
        self._building_shelf_slots={}
        self:_build_sections(section_layer, m, tostring(self.opts.layout_style or "standard") == "compact", "section")
        section_slots=self._building_shelf_slots
        self._building_shelf_slots=nil
        self:_remember_section_layer(cache_id,section_layer,self.section_dimen,section_slots)
    else
        section_slots=cached.slots
        if cached.region then
            self.section_dimen=cached.region:copy()
            self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
            cached.used=self._section_cache_clock
        end
    end
    local old = root[self._section_layer_index]
    root[self._section_layer_index] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    -- Old layers stay alive in the bounded cache. They are freed on eviction,
    -- full rebuild or home close, so switching back does not recreate covers.
    self:_mark_dirty("section", previous_region)
    logger.info("[MiuRead][HomeSwitch] layer",
        "key=",tostring(cache_id or "none"),"cache_hit=",tostring(cache_hit),
        "ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    logger.info("[MiuRead][HomeSwitchPerf] section patched",
        "cache_hit=",tostring(cache_hit),"cards=",tostring(#(self.opts.shelf_books or {})),
        "cpu_ms=",tostring(math.floor((os.clock()-started)*1000+.5)),"refresh=ui_then_full")
    return self
end


function HomeWidget:updateHero(hero)
    self.opts = self.opts or {}
    self.opts.hero = hero
    local m = self._metrics_cache
    local root = self[1]
    if not m or not root or not self._static_body_layer_index
        or Screen:getWidth() ~= self._last_screen_w or Screen:getHeight() ~= self._last_screen_h then
        return self:update(self.opts, "content")
    end
    local previous_region = self.content_dimen and self.content_dimen:copy() or nil
    local previous_section = self.section_dimen and self.section_dimen:copy() or nil
    local layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(layer, m, tostring(self.opts.layout_style or "standard") == "compact", "static")
    local current_section = self.section_dimen and self.section_dimen:copy() or nil
    local same_geometry = previous_section and current_section
        and previous_section.x == current_section.x and previous_section.y == current_section.y
        and previous_section.w == current_section.w and previous_section.h == current_section.h
    if not same_geometry then
        if layer.free then pcall(layer.free, layer) end
        return self:update(self.opts, "content")
    end
    local old = root[self._static_body_layer_index]
    root[self._static_body_layer_index] = layer
    self._static_body_layer = layer
    if old and old ~= layer and old.free then pcall(old.free, old) end
    self:_mark_dirty("content", previous_region)
    return self
end

function HomeWidget:updateBook(book_id)
    local key=tostring(book_id or "")
    if key=="" then return false end
    -- The active layer is patched below. Only other cached layers containing
    -- this book need rebuilding; unrelated shelves keep their rendered cards.
    local cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    for id,entry in pairs(cache) do
        if entry.layer~=self._section_layer and entry.slots and entry.slots[key] then
            cache[id]=nil
            if entry.layer and entry.layer.free then pcall(entry.layer.free,entry.layer) end
        end
    end
    local slots=type(self._section_book_slots)=="table" and self._section_book_slots or {}
    local slot=slots[key]
    if not slot or not slot.parent or not slot.index then return false end
    local book
    for _,candidate in ipairs(self.opts.shelf_books or {}) do
        if shelf_book_key(candidate)==key then book=candidate; break end
    end
    if not book then return false end
    local old=slot.parent[slot.index]
    local replacement=OffsetContainer:new{
        x_off=slot.x,y_off=slot.y,
        shelf_book_card(book,slot.w,slot.h,self.opts.on_open_book,self.opts.on_hold_book),
    }
    slot.parent[slot.index]=replacement
    slot.book=book
    if old and old~=replacement and old.free then pcall(old.free,old) end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,slot.x-safety)
    local y=math.max(0,slot.y-safety)
    local right=math.min(Screen:getWidth(),slot.x+slot.w+safety)
    local bottom=math.min(Screen:getHeight(),slot.y+slot.h+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    logger.info("[MiuRead][HomeBook] updated", "book=",key,"w=",tostring(slot.w),"h=",tostring(slot.h))
    return true
end

function HomeWidget:init()
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        if Device.input and Device.input.group and Device.input.group.Back then
            self.key_events.Back = {{Device.input.group.Back}}
        end
        self.key_events.Menu = {{"Menu"}}
        self.key_events.Home = {{"Home"}}
        if Device.input and Device.input.group then
            if Device.input.group.PgFwd then self.key_events.ShelfNext = {{Device.input.group.PgFwd}} end
            if Device.input.group.PgBack then self.key_events.ShelfPrevious = {{Device.input.group.PgBack}} end
        end
    end
    self:_rebuild()
end

function HomeWidget:onShelfNext()
    self:_notify_resume_interaction("page-next")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(1) end
    return true
end
function HomeWidget:onShelfPrevious()
    self:_notify_resume_interaction("page-previous")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(-1) end
    return true
end

function HomeWidget:onMenu()
    self:_notify_resume_interaction("menu")
    logger.info("[MiuRead][Home] physical menu")
    if self.opts and self.opts.on_menu then self.opts.on_menu() end
    return true
end
function HomeWidget:onBack()
    self:_notify_resume_interaction("back")
    if self.opts and self.opts.on_back then
        local ok,handled=pcall(self.opts.on_back)
        if ok and handled==true then
            logger.info("[MiuRead][Home] back handled by current section")
            return true
        end
    end
    -- The MiuRead home is the root page. Back must not leak to FileManager.
    logger.info("[MiuRead][Home] back consumed at root")
    return true
end
function HomeWidget:onHome()
    self:_notify_resume_interaction("home")
    logger.info("[MiuRead][Home] home consumed at root")
    return true
end

function HomeWidget:onSetDimensions()
    return self:_schedule_dimension_refresh()
end
function HomeWidget:_close_rotation_transients()
    local stack = UIManager._window_stack or {}
    for index = #stack, 1, -1 do
        local widget = stack[index] and stack[index].widget or nil
        if widget and widget ~= self and widget._miuread_transient == true
            and widget.name ~= "miuread_full_shelf"
            and UIManager:isWidgetShown(widget) then
            pcall(UIManager.close, UIManager, widget)
        end
    end
end

function HomeWidget:_capture_pending_dimensions()
    self._pending_screen_w=Screen:getWidth()
    self._pending_screen_h=Screen:getHeight()
    self._pending_rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_dimension_refresh=true
    return true
end

function HomeWidget:_commit_pending_dimensions(force_rebuild)
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_screen_w,self._pending_screen_h=sw,sh
    self._pending_rotation=rotation
    local changed=force_rebuild==true or sw~=self._last_screen_w or sh~=self._last_screen_h
        or rotation~=self._last_rotation
    self._pending_dimension_refresh=false
    if not changed then return false end
    self:_close_rotation_transients()
    self:_clear_inactive_section_cache()
    self:_rebuild()
    return true
end

function HomeWidget:_schedule_dimension_refresh()
    self._dimension_refresh_generation = (tonumber(self._dimension_refresh_generation) or 0) + 1
    local generation = self._dimension_refresh_generation
    if self._dimension_refresh_task then
        UIManager:unschedule(self._dimension_refresh_task)
        self._dimension_refresh_task=nil
    end
    self:_capture_pending_dimensions()

    -- Parked Home and the lock-screen path must stay completely passive. The
    -- latest geometry is applied once, immediately before Home becomes active.
    if self._miu_input_suspended==true or self._miu_device_suspended==true then
        return true
    end

    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._miu_closed or self._dimension_refresh_task~=task
            or generation ~= self._dimension_refresh_generation then return end
        if self._miu_input_suspended==true or self._miu_device_suspended==true then
            self._dimension_refresh_task=nil
            self:_capture_pending_dimensions()
            return
        end
        attempts=attempts+1
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
        if sw==last_w and sh==last_h and rotation==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=sw,sh,rotation,0
        end
        if stable<2 and attempts<8 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._dimension_refresh_task=nil
        local changed=self:_commit_pending_dimensions(false)
        if changed then UIManager:setDirty(self,"full") end
        logger.info("[MiuRead][Rotation] home committed",
            "samples=",tostring(attempts),"changed=",tostring(changed),
            "size=",tostring(sw).."x"..tostring(sh),"rotation=",tostring(rotation))
    end
    self._dimension_refresh_task=task
    UIManager:scheduleIn(.30,task)
    return true
end
function HomeWidget:onScreenResize() return self:_schedule_dimension_refresh() end
function HomeWidget:onRotation() return self:_schedule_dimension_refresh() end

function HomeWidget:onCloseWidget()
    self._miu_closed = true
    self._dimension_refresh_generation=(tonumber(self._dimension_refresh_generation) or 0)+1
    if self._dimension_refresh_task then UIManager:unschedule(self._dimension_refresh_task); self._dimension_refresh_task=nil end
    if self._section_clean_refresh_task then UIManager:unschedule(self._section_clean_refresh_task); self._section_clean_refresh_task=nil end
    self:_clear_inactive_section_cache()
    if live_widget == self then live_widget = nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close, self) end
end

local HomeView = {}
local function stacked_home_widgets()
    local rows = {}
    for _, window in ipairs(UIManager._window_stack or {}) do
        local widget = window and window.widget or nil
        if widget and widget.name == "miuread_home" and not widget._miu_closed then rows[#rows + 1] = widget end
    end
    return rows
end
function HomeView.prune_duplicates()
    local rows = stacked_home_widgets()
    if #rows == 0 then
        if live_widget and (live_widget._miu_closed or not UIManager:isWidgetShown(live_widget)) then live_widget = nil end
        return 0
    end
    local keep = nil
    if live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget) then keep = live_widget end
    if not keep then keep = rows[#rows]; live_widget = keep end
    local closed = 0
    for _, widget in ipairs(rows) do
        if widget ~= keep then
            widget._miu_superseded = true
            widget._miu_suppress_restore = true
            pcall(UIManager.close, UIManager, widget)
            closed = closed + 1
        end
    end
    if closed > 0 then logger.warn("[MiuRead][Home] duplicate roots removed", tostring(closed)) end
    return closed
end
function HomeView.current() return live_widget end
function HomeView.is_shown()
    HomeView.prune_duplicates()
    return live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget)
end
function HomeView.is_parked()
    return HomeView.is_shown() and live_widget._miu_input_suspended==true
end
-- Keep the rendered home in UIManager's stack while ReaderUI owns the screen.
-- This avoids briefly exposing FileManager during open/close, while disabling
-- all home input prevents the stale gesture-zone issue seen in older builds.
function HomeView.park()
    if not HomeView.is_shown() then return false end
    live_widget._miu_input_suspended=true
    live_widget._miu_resume_interaction_callback=nil
    live_widget._miu_resume_waiting_interaction=false
    if live_widget._section_clean_refresh_task then
        UIManager:unschedule(live_widget._section_clean_refresh_task)
        live_widget._section_clean_refresh_task=nil
    end
    -- Reader keeps only the currently visible lightweight shell. Inactive
    -- rendered section layers (and their cover surfaces) are released here.
    if type(live_widget._clear_inactive_section_cache)=="function" then live_widget:_clear_inactive_section_cache() end
    logger.info("[MiuRead][HomeShell] parked light","active_section=",tostring(live_widget.opts and live_widget.opts.section_cache_key or ""))
    return true
end
function HomeView.suspend()
    if not HomeView.is_shown() then return false end
    live_widget._miu_device_suspended=true
    live_widget._dimension_refresh_generation=(tonumber(live_widget._dimension_refresh_generation) or 0)+1
    if live_widget._dimension_refresh_task then
        UIManager:unschedule(live_widget._dimension_refresh_task)
        live_widget._dimension_refresh_task=nil
    end
    live_widget:_capture_pending_dimensions()
    return true
end
function HomeView.unpark(skip_dirty,opts)
    if not HomeView.is_shown() then return false end
    opts=type(opts)=="table" and opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(false)
    live_widget._miu_input_suspended=false
    if type(opts.on_interaction)=="function" then
        live_widget._miu_resume_interaction_callback=opts.on_interaction
        live_widget._miu_resume_waiting_interaction=true
        live_widget._miu_last_interaction_at=0
    end
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    if skip_dirty~=true then UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    elseif rebuilt then UIManager:setDirty(live_widget,"full") end
    return true
end
-- FileManager is recreated after ReaderUI closes so KOReader's docless
-- plugins (including Gesture Manager) remain alive beneath MiuRead. Move the
-- already-built home above that native base without closing/rebuilding it.
function HomeView.raise(skip_dirty)
    HomeView.prune_duplicates()
    if not HomeView.is_shown() then return false end
    local stack = UIManager._window_stack or {}
    local window, index
    for i = #stack, 1, -1 do
        if stack[i] and stack[i].widget == live_widget then
            window, index = stack[i], i
            break
        end
    end
    if not window then return false end
    table.remove(stack, index)
    local insert_at = 1
    -- Match UIManager:show ordering for a standard non-modal widget: below
    -- modal dialogs/toasts, above the uppermost normal page.
    for i = #stack, 0, -1 do
        local top = stack[i]
        if top and top.widget and top.widget.toast then
            -- Keep looking below the toast group.
        elseif not top or not top.widget or not top.widget.modal then
            insert_at = i + 1
            break
        end
    end
    table.insert(stack, insert_at, window)
    if skip_dirty~=true then UIManager:setDirty(live_widget, "ui") end
    return true
end
function HomeView.resume(opts)
    if not HomeView.is_shown() then return false end
    opts=opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(opts.rebuild_visual==true)
    live_widget._miu_input_suspended=false
    live_widget._miu_resume_interaction_callback=opts.on_interaction
    live_widget._miu_resume_waiting_interaction=true
    live_widget._miu_last_interaction_at=0
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    -- Resume never reorders UIManager._window_stack. If the long-sleep visual
    -- geometry is stale, rebuild this existing widget in place and repaint it.
    UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    return true
end

function HomeView.close(full_refresh)
    HomeView.prune_duplicates()
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    live_widget = nil
    if full_refresh == true then
        UIManager:scheduleIn(.04, function()
            if UIManager._exit_code == nil then UIManager:setDirty("all", "full") end
        end)
    end
end
function HomeView.refresh(kind)
    if not HomeView.is_shown() then return false end
    local ok, err = pcall(live_widget.update, live_widget, live_widget.opts or {}, kind or "content")
    if not ok then logger.warn("[MiuRead][Home] refresh failed", tostring(err)); return false end
    return true
end
function HomeView.update_header(fields)
    if not HomeView.is_shown() or not live_widget.updateHeader then return false end
    local ok, updated = pcall(live_widget.updateHeader, live_widget, fields or {})
    if not ok then logger.warn("[MiuRead][Home] header update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_time(text)
    if not HomeView.is_shown() or not live_widget.updateDashboard then return false end
    local ok, updated = pcall(live_widget.updateDashboard, live_widget, {clock_text=tostring(text or "--:--")})
    if not ok then logger.warn("[MiuRead][Home] clock update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_dashboard(fields)
    if not HomeView.is_shown() or not live_widget.updateDashboard then return false end
    local ok, updated = pcall(live_widget.updateDashboard, live_widget, fields or {})
    if not ok then logger.warn("[MiuRead][Home] dashboard update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_section(opts)
    if not HomeView.is_shown() or not live_widget.updateSection then return false end
    local ok, err = pcall(live_widget.updateSection, live_widget, opts or {})
    if not ok then logger.warn("[MiuRead][Home] section update failed", tostring(err)); return false end
    return true
end
function HomeView.shelf_thumbnail_size(oversample)
    if HomeView.is_shown() and live_widget then
        local slots=type(live_widget._section_book_slots)=="table" and live_widget._section_book_slots or {}
        for _,slot in pairs(slots) do
            if slot and tonumber(slot.w) and tonumber(slot.h) then
                return shelf_cover_target_size(slot.w,slot.h,oversample)
            end
        end
    end
    -- Match the initial orientation before live shelf slots are available.
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local card_w=math.max(1,math.floor(sw/(sw<sh and 3 or 6)))
    local card_h=math.max(1,math.floor(sh*.30))
    return shelf_cover_target_size(card_w,card_h,oversample)
end

function HomeView.update_book(book_id)
    if not HomeView.is_shown() or not live_widget.updateBook then return false end
    local ok, updated = pcall(live_widget.updateBook, live_widget, book_id)
    if not ok then logger.warn("[MiuRead][Home] book update failed", tostring(updated)); return false end
    return updated==true
end
function HomeView.update_hero(hero)
    if not HomeView.is_shown() or not live_widget.updateHero then return false end
    local ok, updated = pcall(live_widget.updateHero, live_widget, hero)
    if not ok then logger.warn("[MiuRead][Home] hero update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.show(opts, refresh_kind)
    opts = opts or {}
    HomeView.prune_duplicates()
    if HomeView.is_shown() then
        local ok, err = pcall(live_widget.update, live_widget, opts, refresh_kind)
        if ok then return live_widget end
        logger.warn("[MiuRead][Home] in-place update failed", tostring(err))
    end
    if live_widget and not live_widget._miu_closed then
        live_widget._miu_superseded = true
        live_widget._miu_suppress_restore = true
        UIManager:close(live_widget)
    end
    local ok, widget = pcall(HomeWidget.new, HomeWidget, {opts = opts})
    if not ok or not widget then
        logger.err("[MiuRead][Home] build failed", tostring(widget))
        return nil, tostring(widget)
    end
    home_generation = home_generation + 1
    widget._miu_home_generation = home_generation
    widget._miu_resume_interaction_callback=opts.on_interaction
    widget._miu_resume_waiting_interaction=false
    live_widget = widget
    UIManager:show(widget, "ui", widget.dimen)
    HomeView.prune_duplicates()
    return widget
end
return HomeView
