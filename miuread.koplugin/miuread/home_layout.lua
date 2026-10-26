-- Shared geometry keeps pagination, rendering and cover derivatives in sync.
local Layout = {PAGE_SIZE = 6}

local function rounded(value) return math.max(1, math.floor(value + .5)) end

function Layout.metrics(width, height)
    local short = math.min(width, height)
    local portrait = width < height
    local margin = rounded(short * .038)
    local top = rounded(short * .012)
    local gap = rounded(short * .012)
    local header_h = rounded(short * .078)
    local nav_h = rounded(short * .078)
    local body_y = top + header_h + gap
    return {
        sw = width, sh = height, portrait = portrait,
        margin = margin, top = top, gap = gap,
        content_w = width - margin * 2, header_h = header_h,
        body_y = body_y, body_h = height - nav_h - gap - body_y,
        hero_h = rounded(height * (portrait and .235 or .21)),
        stats_h = rounded(short * .064),
        shelf_heading_h = rounded(short * .051),
        tabs_h = rounded(short * .049),
        footer_h = rounded(short * .035),
        nav_h = nav_h, nav_y = height - nav_h,
        columns = portrait and 3 or 6, rows = portrait and 2 or 1,
    }
end

function Layout.grid(metrics, width, height)
    local columns, rows = metrics.columns, metrics.rows
    local column_gap = metrics.gap * 2
    local row_gap = metrics.gap
    return columns, rows, column_gap, row_gap,
        math.max(1, math.floor((width - column_gap * (columns - 1)) / columns)),
        math.max(1, math.floor((height - row_gap * (rows - 1)) / rows))
end

return Layout
