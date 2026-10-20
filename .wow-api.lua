-- WoW API globals referenced by TrickOrRoute.
--
-- Linting-only stub: never loaded by the game (not listed in the .toc).
-- It declares the World of Warcraft globals the addon touches so a Lua
-- language server (lua-language-server / pi-lens) doesn't report them as
-- undefined; shapes are loose on purpose, matching the addon's defensive use.

-- Frames and UI
CreateFrame = CreateFrame or function() return nil end
UIParent = UIParent
Minimap = Minimap
WorldMapFrame = WorldMapFrame
GameTooltip = GameTooltip
UISpecialFrames = UISpecialFrames
UIPanelCloseButton = UIPanelCloseButton
UIPanelButtonTemplate = UIPanelButtonTemplate
UICheckButtonTemplate = UICheckButtonTemplate
BackdropTemplate = BackdropTemplate
UIPanelScrollFrameTemplate = UIPanelScrollFrameTemplate
OptionsSliderTemplate = OptionsSliderTemplate
GameFontHighlight = GameFontHighlight
GameFontHighlightSmall = GameFontHighlightSmall
GameFontHighlightLarge = GameFontHighlightLarge
GameFontNormal = GameFontNormal
GameFontNormalLarge = GameFontNormalLarge
GameFontNormalSmall = GameFontNormalSmall
GameFontDisable = GameFontDisable
GameFontDisableSmall = GameFontDisableSmall

-- Slash commands
SlashCmdList = SlashCmdList or {}

-- C_* namespaces (loose tables; the game fills them in)
C_Item = C_Item
C_Map = C_Map
C_QuestLog = C_QuestLog
C_SuperTrack = C_SuperTrack
C_Timer = C_Timer
C_Reputation = C_Reputation
C_TaxiMap = C_TaxiMap

-- Item API, legacy and modern
GetItemIcon = GetItemIcon
GetItemCount = GetItemCount

-- Quest and player state
UnitFactionGroup = UnitFactionGroup
GetPlayerFacing = GetPlayerFacing
IsShiftKeyDown = IsShiftKeyDown
IsControlKeyDown = IsControlKeyDown
IsIndoors = IsIndoors
GetCursorPosition = GetCursorPosition

-- Sound
PlaySound = PlaySound
SOUNDKIT = SOUNDKIT

-- Client helpers
Enum = Enum
Settings = Settings
InterfaceOptions_AddCategory = InterfaceOptions_AddCategory
InterfaceOptionsFrame_OpenToCategory = InterfaceOptionsFrame_OpenToCategory
GetCVar = GetCVar
date = date
MAP_PIN_HYPERLINK = MAP_PIN_HYPERLINK
ChatFrameUtil = ChatFrameUtil
ChatEdit_InsertLink = ChatEdit_InsertLink
ChatFrame_OpenChat = ChatFrame_OpenChat
wipe = wipe
tinsert = tinsert
hooksecurefunc = hooksecurefunc
CreateVector2D = CreateVector2D
GetMinimapShape = GetMinimapShape

-- Other addons (optional integrations)
TomTom = TomTom
