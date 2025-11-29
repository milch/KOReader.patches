--[[
    This user patch adds a cyclable "header" into the reader display that combines functionality
    from multiple header styles and allows cycling through different views by tapping the header
    region.

    View Modes (cycles in this order):
    1. Clean (nothing displayed)
    2. Print edition style (alternates page number position and centered text)
    3. Book title (top left) + current time (top right)
    4. Current chapter (top left) + current time (top right)
    5. Current time (centered)
    6. Author + separator + title + separator + chapter (centered)

    Default: Current time centered (mode 5)

    To cycle through views: Tap the top-center of the screen
    (specifically: the center third horizontally, top 5% vertically)

    This leaves the top corners available for bookmarks, rotation toggle, etc.

    It is up to you to provide enough of a top margin so that your book contents are not
    obscured by the header. You'll know right away if you need to increase the top margin.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local BD = require("ui/bidi")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Device = require("device")
local Font = require("ui/font")
local logger = require("logger")
local util = require("util")
local datetime = require("datetime")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")

-- Store original functions
local _ReaderView_paintTo_orig = ReaderView.paintTo
local _ReaderUI_init_orig = ReaderUI.init

-- Settings key for storing current mode
local SETTINGS_KEY = "header_cycling_mode"

-- Get initial mode from settings, default to mode 5 (time centered)
local current_mode = G_reader_settings:readSetting(SETTINGS_KEY) or 5

-- View mode constants
local MODE_CLEAN = 1
local MODE_PRINT_EDITION = 2
local MODE_TITLE_TIME = 3
local MODE_CHAPTER_TIME = 4
local MODE_TIME_CENTER = 5
local MODE_FULL_INFO = 6
local MODE_COUNT = 6

local header_settings = G_reader_settings:readSetting("footer")
local screen_width = Screen:getWidth()
local screen_height = Screen:getHeight()

-- Function to cycle to next mode
local function cycleMode(readerui_instance)
	current_mode = current_mode + 1
	if current_mode > MODE_COUNT then
		current_mode = 1
	end
	G_reader_settings:saveSetting(SETTINGS_KEY, current_mode)
	logger.dbg("Header cycling mode changed to:", current_mode)
	UIManager:setDirty(readerui_instance.dialog, "ui")
end

-- Hook into ReaderUI initialization to register touch zone
ReaderUI.init = function(self, ...)
	local ret = _ReaderUI_init_orig(self, ...)

	-- Register touch zone for header taps (top 5% of screen, center third only)
	-- This leaves the top corners available for other gestures
	self:registerTouchZones({
		{
			id = "reader_header_cycling",
			ges = "tap",
			screen_zone = {
				ratio_x = 0.33, -- Start at 1/3 from left (skip left third)
				ratio_y = 0, -- Top of screen
				ratio_w = 0.34, -- Middle third (from 0.33 to 0.67)
				ratio_h = 0.05, -- Top 5% of screen
			},
			handler = function(ges)
				cycleMode(self)
				return true
			end,
		},
	})

	return ret
end

-- Override paintTo to draw the header
ReaderView.paintTo = function(self, bb, x, y)
	_ReaderView_paintTo_orig(self, bb, x, y)
	if self.render_mode ~= nil then
		return
	end -- Show only for epub-likes and never on pdf-likes

	-- Mode 1: Clean - show nothing
	if current_mode == MODE_CLEAN then
		return
	end

	-- ===========================!!!!!!!!!!!!!!!=========================== -
	-- Configure formatting options for header here, if desired
	local header_font_face = "ffont" -- this is the same font the footer uses
	local header_font_size = header_settings.text_font_size or 14
	local header_font_bold = header_settings.text_font_bold or false
	local header_font_color = Blitbuffer.COLOR_BLACK
	local header_top_padding = Size.padding.small
	local header_bottom_padding = header_settings.container_height or 7
	local header_use_book_margins = true
	local header_margin = Size.padding.large
	local left_max_width_pct = 48
	local right_max_width_pct = 48
	local header_max_width_pct = 84
	local separator = {
		bar = "|",
		bullet = "•",
		dot = "·",
		em_dash = "—",
		en_dash = "-",
	}
	-- ===========================!!!!!!!!!!!!!!!=========================== -

	-- Gather all the data we might need
	local book_title = ""
	local book_author = ""
	if self.ui.doc_props then
		book_title = self.ui.doc_props.display_title or ""
		book_author = self.ui.doc_props.authors or ""
		if book_author:find("\n") then
			book_author = T(_("%1 et al."), util.splitToArray(book_author, "\n")[1] .. ",")
		end
	end

	local pageno = self.state.page or 1

	local book_chapter = ""
	local pages_done = 0
	if self.ui.toc then
		book_chapter = self.ui.toc:getTocTitleByPage(pageno) or ""
		pages_done = self.ui.toc:getChapterPagesDone(pageno) or 0
	end
	pages_done = pages_done + 1

	local time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""

	-- Calculate margins
	local margins = 0
	local left_margin = header_margin
	local right_margin = header_margin
	if header_use_book_margins then
		left_margin = self.document:getPageMargins().left or header_margin
		right_margin = self.document:getPageMargins().right or header_margin
	end
	margins = left_margin + right_margin
	local avail_width = screen_width - margins

	-- Helper function to fit text
	local function getFittedText(text, max_width_pct)
		if text == nil or text == "" then
			return ""
		end
		local text_widget = TextWidget:new({
			text = text:gsub(" ", "\u{00A0}"),
			max_width = avail_width * max_width_pct * (1 / 100),
			face = Font:getFace(header_font_face, header_font_size),
			bold = header_font_bold,
			padding = 0,
		})
		local fitted_text, add_ellipsis = text_widget:getFittedText()
		text_widget:free()
		if add_ellipsis then
			fitted_text = fitted_text .. "…"
		end
		return BD.auto(fitted_text)
	end

	-- Determine what to display based on current mode
	local left_corner_header = ""
	local right_corner_header = ""
	local centered_header = ""

	if current_mode == MODE_PRINT_EDITION then
		-- Mode 2: Print edition style
		if (pages_done > 1) and (pageno % 2 == 0) then
			left_corner_header = string.format("%d", pageno)
			centered_header = string.format("%s %s %s", book_author, separator.en_dash, book_title)
		elseif (pages_done > 1) and (pageno % 2 ~= 0) then
			right_corner_header = string.format("%d", pageno)
			centered_header = string.format("%s", book_chapter)
		elseif pages_done == 1 then
			centered_header = string.format("%d", pageno)
		end
	elseif current_mode == MODE_TITLE_TIME then
		-- Mode 3: Book title (left) + time (right)
		left_corner_header = book_title
		right_corner_header = time
	elseif current_mode == MODE_CHAPTER_TIME then
		-- Mode 4: Chapter (left) + time (right)
		left_corner_header = book_chapter
		right_corner_header = time
	elseif current_mode == MODE_TIME_CENTER then
		-- Mode 5: Time centered
		centered_header = time
	elseif current_mode == MODE_FULL_INFO then
		-- Mode 6: Author + separator + title + separator + chapter (centered)
		centered_header =
			string.format("%s %s %s %s %s", book_author, separator.en_dash, book_title, separator.en_dash, book_chapter)
	end

	-- Fit the text to available width
	left_corner_header = getFittedText(left_corner_header, left_max_width_pct)
	right_corner_header = getFittedText(right_corner_header, right_max_width_pct)

	-- Draw corner headers (if any)
	if left_corner_header ~= "" or right_corner_header ~= "" then
		local left_header_text = TextWidget:new({
			text = left_corner_header,
			face = Font:getFace(header_font_face, header_font_size),
			bold = header_font_bold,
			fgcolor = header_font_color,
			padding = 0,
		})
		local right_header_text = TextWidget:new({
			text = right_corner_header,
			face = Font:getFace(header_font_face, header_font_size),
			bold = header_font_bold,
			fgcolor = header_font_color,
			padding = 0,
		})
		local dynamic_space = avail_width - left_header_text:getSize().w - right_header_text:getSize().w
		local header = CenterContainer:new({
			dimen = Geom:new({
				w = screen_width,
				h = math.max(left_header_text:getSize().h, right_header_text:getSize().h) + header_top_padding,
			}),
			VerticalGroup:new({
				VerticalSpan:new({ width = header_top_padding }),
				HorizontalGroup:new({
					left_header_text,
					HorizontalSpan:new({ width = dynamic_space }),
					right_header_text,
				}),
			}),
		})
		header:paintTo(bb, x, y)
		header:free()
	end

	-- Draw centered header (if any)
	if centered_header ~= "" then
		centered_header = getFittedText(centered_header, header_max_width_pct)
		local header_text = TextWidget:new({
			text = centered_header,
			face = Font:getFace(header_font_face, header_font_size),
			bold = header_font_bold,
			fgcolor = header_font_color,
			padding = 0,
		})

		-- Special case for print edition mode: show page number at bottom on first page of chapter
		local top_padding = header_top_padding
		if current_mode == MODE_PRINT_EDITION and pages_done == 1 then
			top_padding = screen_height - header_text:getSize().h - header_bottom_padding
		end

		local header = CenterContainer:new({
			dimen = Geom:new({ w = screen_width, h = header_text:getSize().h + top_padding }),
			VerticalGroup:new({
				VerticalSpan:new({ width = top_padding }),
				HorizontalGroup:new({
					HorizontalSpan:new({ width = left_margin }),
					header_text,
					HorizontalSpan:new({ width = right_margin }),
				}),
			}),
		})
		header:paintTo(bb, x, y)
		header:free()
	end
end
