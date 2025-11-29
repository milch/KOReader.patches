--[[
	This user patch adds a cyclable "header" into the reader display that combines functionality
	from multiple header styles.

	View Modes:
	1. Clean (nothing displayed)
	2. Print edition style (alternates page number position and centered text)
	3. Book title (top left) + current time (top right)
	4. Current chapter (top left) + current time (top right)
	5. Current time (centered)
	6. Author + separator + title + separator + chapter (centered)

	Default: Current time centered (mode 5)

	Access via Status bar → Header menu:
	- "Select Header Mode" - Choose a specific mode directly
	- "Previous Header Mode" - Cycle backward through modes
	- "Next Header Mode" - Cycle forward through modes
	- "Header Settings" - Configure font size, padding, separators, and widths

	Gesture Control:
	You can bind gestures to cycle modes in Settings → Taps and gestures → Gesture manager:
	- "Next Header Mode" - Cycle forward through header modes
	- "Previous Header Mode" - Cycle backward through header modes

	All settings are configurable via the menu system - no need to edit this file!

	Note: You may need to provide sufficient top margin so the header doesn't overlap your text.
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
local ReaderFooter = require("apps/reader/modules/readerfooter")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")

-- Store original functions
local _ReaderView_paintTo_orig = ReaderView.paintTo
local _ReaderFooter_addToMainMenu_orig = ReaderFooter.addToMainMenu

-- Settings keys
local SETTINGS_KEY_MODE = "header_cycling_mode"
local SETTINGS_KEY_FONT_SIZE = "header_cycling_font_size"
local SETTINGS_KEY_FONT_BOLD = "header_cycling_font_bold"
local SETTINGS_KEY_TOP_PADDING = "header_cycling_top_padding"
local SETTINGS_KEY_USE_BOOK_MARGINS = "header_cycling_use_book_margins"
local SETTINGS_KEY_SEPARATOR = "header_cycling_separator"
local SETTINGS_KEY_LEFT_WIDTH = "header_cycling_left_width"
local SETTINGS_KEY_RIGHT_WIDTH = "header_cycling_right_width"
local SETTINGS_KEY_CENTER_WIDTH = "header_cycling_center_width"

-- Get initial mode from settings, default to mode 5 (time centered)
local current_mode = G_reader_settings:readSetting(SETTINGS_KEY_MODE) or 5

-- Helper function to get settings with defaults
local function getSetting(key, default)
	local value = G_reader_settings:readSetting(key)
	if value ~= nil then
		return value
	end
	return default
end

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

-- Separator types
local SEPARATOR_TYPES = {
	bar = "|",
	bullet = "•",
	dot = "·",
	em_dash = "—",
	en_dash = "-",
}

-- Padding size options
local PADDING_SIZES = {
	small = Size.padding.small,
	default = Size.padding.default,
	large = Size.padding.large,
}

-- Mode names for display
local MODE_NAMES = {
	[MODE_CLEAN] = _("Clean (nothing)"),
	[MODE_PRINT_EDITION] = _("Print edition"),
	[MODE_TITLE_TIME] = _("Title + Time"),
	[MODE_CHAPTER_TIME] = _("Chapter + Time"),
	[MODE_TIME_CENTER] = _("Time (centered)"),
	[MODE_FULL_INFO] = _("Full info (author/title/chapter)"),
}

-- Set mode and refresh display
local function setMode(mode, readerui_instance)
	current_mode = mode
	G_reader_settings:saveSetting(SETTINGS_KEY_MODE, current_mode)
	logger.dbg("Header mode changed to:", current_mode, MODE_NAMES[current_mode])
	if readerui_instance then
		UIManager:setDirty(readerui_instance.dialog, "ui")
	end
end

-- Cycle to next mode
local function cycleNext(readerui_instance)
	local next_mode = current_mode + 1
	if next_mode > MODE_COUNT then
		next_mode = 1
	end
	setMode(next_mode, readerui_instance)
end

-- Cycle to previous mode
local function cyclePrevious(readerui_instance)
	local prev_mode = current_mode - 1
	if prev_mode < 1 then
		prev_mode = MODE_COUNT
	end
	setMode(prev_mode, readerui_instance)
end

-- Hook into ReaderFooter to add menu items to status bar
ReaderFooter.addToMainMenu = function(self, menu_items)
	-- Build the menu structure
	local function buildHeaderModeMenu()
		-- Create submenu for direct mode selection
		local mode_submenu = {}
		for i = 1, MODE_COUNT do
			table.insert(mode_submenu, {
				text = MODE_NAMES[i],
				checked_func = function()
					return current_mode == i
				end,
				callback = function()
					setMode(i, self.ui)
				end,
			})
		end

		-- Create separator submenu
		local separator_submenu = {}
		for name, symbol in pairs(SEPARATOR_TYPES) do
			table.insert(separator_submenu, {
				text = string.format("%s (%s)", name:gsub("_", " "), symbol),
				checked_func = function()
					return getSetting(SETTINGS_KEY_SEPARATOR, "en_dash") == name
				end,
				callback = function()
					G_reader_settings:saveSetting(SETTINGS_KEY_SEPARATOR, name)
					UIManager:setDirty(self.ui.dialog, "ui")
				end,
			})
		end

		return {
			text = _("Header"),
			sub_item_table = {
				{
					text = _("Select Header Mode"),
					sub_item_table = mode_submenu,
				},
				{
					text = _("Previous Header Mode"),
					callback = function()
						cyclePrevious(self.ui)
					end,
				},
				{
					text = _("Next Header Mode"),
					callback = function()
						cycleNext(self.ui)
					end,
				},
				{
					text = _("Header Settings"),
					sub_item_table = {
						{
							text = _("Font Size"),
							callback = function()
								local SpinWidget = require("ui/widget/spinwidget")
								local current_size =
									getSetting(SETTINGS_KEY_FONT_SIZE, header_settings.text_font_size or 14)
								local spin = SpinWidget:new({
									title_text = _("Header Font Size"),
									value = current_size,
									value_min = 8,
									value_max = 36,
									value_step = 1,
									value_hold_step = 2,
									ok_text = _("Set"),
									callback = function(spin)
										G_reader_settings:saveSetting(SETTINGS_KEY_FONT_SIZE, spin.value)
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								})
								UIManager:show(spin)
							end,
						},
						{
							text = _("Bold Font"),
							checked_func = function()
								return getSetting(SETTINGS_KEY_FONT_BOLD, header_settings.text_font_bold or false)
							end,
							callback = function()
								local current =
									getSetting(SETTINGS_KEY_FONT_BOLD, header_settings.text_font_bold or false)
								G_reader_settings:saveSetting(SETTINGS_KEY_FONT_BOLD, not current)
								UIManager:setDirty(self.ui.dialog, "ui")
							end,
						},
						{
							text = _("Top Padding"),
							sub_item_table = {
								{
									text = _("Small"),
									checked_func = function()
										return getSetting(SETTINGS_KEY_TOP_PADDING, "small") == "small"
									end,
									callback = function()
										G_reader_settings:saveSetting(SETTINGS_KEY_TOP_PADDING, "small")
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								},
								{
									text = _("Default"),
									checked_func = function()
										return getSetting(SETTINGS_KEY_TOP_PADDING, "small") == "default"
									end,
									callback = function()
										G_reader_settings:saveSetting(SETTINGS_KEY_TOP_PADDING, "default")
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								},
								{
									text = _("Large"),
									checked_func = function()
										return getSetting(SETTINGS_KEY_TOP_PADDING, "small") == "large"
									end,
									callback = function()
										G_reader_settings:saveSetting(SETTINGS_KEY_TOP_PADDING, "large")
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								},
							},
						},
						{
							text = _("Text Separator"),
							sub_item_table = separator_submenu,
						},
						{
							text = _("Use Book Margins"),
							checked_func = function()
								return getSetting(SETTINGS_KEY_USE_BOOK_MARGINS, true)
							end,
							callback = function()
								local current = getSetting(SETTINGS_KEY_USE_BOOK_MARGINS, true)
								G_reader_settings:saveSetting(SETTINGS_KEY_USE_BOOK_MARGINS, not current)
								UIManager:setDirty(self.ui.dialog, "ui")
							end,
						},
						{
							text = _("Left Corner Max Width %"),
							keep_menu_open = true,
							callback = function()
								local SpinWidget = require("ui/widget/spinwidget")
								local current_width = getSetting(SETTINGS_KEY_LEFT_WIDTH, 48)
								local spin = SpinWidget:new({
									title_text = _("Left Corner Max Width %"),
									value = current_width,
									value_min = 10,
									value_max = 90,
									value_step = 1,
									value_hold_step = 5,
									ok_text = _("Set"),
									callback = function(spin)
										G_reader_settings:saveSetting(SETTINGS_KEY_LEFT_WIDTH, spin.value)
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								})
								UIManager:show(spin)
							end,
						},
						{
							text = _("Right Corner Max Width %"),
							keep_menu_open = true,
							callback = function()
								local SpinWidget = require("ui/widget/spinwidget")
								local current_width = getSetting(SETTINGS_KEY_RIGHT_WIDTH, 48)
								local spin = SpinWidget:new({
									title_text = _("Right Corner Max Width %"),
									value = current_width,
									value_min = 10,
									value_max = 90,
									value_step = 1,
									value_hold_step = 5,
									ok_text = _("Set"),
									callback = function(spin)
										G_reader_settings:saveSetting(SETTINGS_KEY_RIGHT_WIDTH, spin.value)
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								})
								UIManager:show(spin)
							end,
						},
						{
							text = _("Center Max Width %"),
							keep_menu_open = true,
							callback = function()
								local SpinWidget = require("ui/widget/spinwidget")
								local current_width = getSetting(SETTINGS_KEY_CENTER_WIDTH, 84)
								local spin = SpinWidget:new({
									title_text = _("Center Max Width %"),
									value = current_width,
									value_min = 10,
									value_max = 100,
									value_step = 1,
									value_hold_step = 5,
									ok_text = _("Set"),
									callback = function(spin)
										G_reader_settings:saveSetting(SETTINGS_KEY_CENTER_WIDTH, spin.value)
										UIManager:setDirty(self.ui.dialog, "ui")
									end,
								})
								UIManager:show(spin)
							end,
						},
					},
				},
			},
		}
	end

	-- Call the original function first
	_ReaderFooter_addToMainMenu_orig(self, menu_items)

	-- Add our menu item to the status bar menu at a specific position
	if menu_items.status_bar and menu_items.status_bar.sub_item_table then
		local status_bar_menu = menu_items.status_bar.sub_item_table

		-- Find the position of "Status bar presets"
		local insert_pos = nil
		for i, item in ipairs(status_bar_menu) do
			local text = item.text or (item.text_func and item.text_func())
			if text == _("Status bar presets") then
				insert_pos = i + 1
				-- Check if next item is already a separator
				break
			end
		end

		-- If we found the position, insert Header Mode and a separator after it
		if insert_pos then
			table.insert(status_bar_menu, insert_pos, buildHeaderModeMenu())
			status_bar_menu[insert_pos].separator = true
		else
			table.insert(status_bar_menu, buildHeaderModeMenu())
		end
	end

	-- Register dispatcher actions for gesture control
	Dispatcher:registerAction("header_mode_next", {
		category = "none",
		event = "HeaderModeNext",
		title = _("Next Header Mode"),
		general = true,
	})
	Dispatcher:registerAction("header_mode_previous", {
		category = "none",
		event = "HeaderModePrevious",
		title = _("Previous Header Mode"),
		general = true,
	})
end

-- Handle dispatcher events
ReaderFooter.onHeaderModeNext = function(self)
	cycleNext(self.ui)
end

ReaderFooter.onHeaderModePrevious = function(self)
	cyclePrevious(self.ui)
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

	-- Get configuration from settings
	local header_font_face = "ffont" -- this is the same font the footer uses
	local header_font_size = getSetting(SETTINGS_KEY_FONT_SIZE, header_settings.text_font_size or 14)
	local header_font_bold = getSetting(SETTINGS_KEY_FONT_BOLD, header_settings.text_font_bold or false)
	local header_font_color = Blitbuffer.COLOR_BLACK
	local header_top_padding = PADDING_SIZES[getSetting(SETTINGS_KEY_TOP_PADDING, "small")]
	local header_bottom_padding = header_settings.container_height or 7
	local header_use_book_margins = getSetting(SETTINGS_KEY_USE_BOOK_MARGINS, true)
	local header_margin = Size.padding.large
	local left_max_width_pct = getSetting(SETTINGS_KEY_LEFT_WIDTH, 48)
	local right_max_width_pct = getSetting(SETTINGS_KEY_RIGHT_WIDTH, 48)
	local header_max_width_pct = getSetting(SETTINGS_KEY_CENTER_WIDTH, 84)
	local separator_type = getSetting(SETTINGS_KEY_SEPARATOR, "en_dash")
	local separator = SEPARATOR_TYPES[separator_type]

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
			centered_header = string.format("%s %s %s", book_author, separator, book_title)
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
		centered_header = string.format("%s %s %s %s %s", book_author, separator, book_title, separator, book_chapter)
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
