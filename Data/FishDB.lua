-- GoblinLedger fishing database: which fish live where, written by GoblinLedger from general
-- classic fishing knowledge. It's a starting guide only - what you actually fish up is recorded
-- (Fishing.lua) and shown next to it, and replaces it over time.
local _, ns = ...

local STARTER = { "Elwynn Forest", "Dun Morogh", "Teldrassil", "Durotar", "Mulgore", "Tirisfal Glades" }
local function plus(a, b)
    local out = {}
    for _, z in ipairs(a) do out[#out + 1] = z end
    for _, z in ipairs(b) do out[#out + 1] = z end
    return out
end

local LOW_COAST = { "Westfall", "Darkshore", "The Barrens", "Silverpine Forest", "Durotar", "Wetlands" }
local HIGH_COAST = { "Feralas", "Tanaris", "Azshara", "The Hinterlands", "Stranglethorn Vale" }
local HIGH_INLAND = { "Feralas", "Felwood", "Moonglade", "The Hinterlands", "Western Plaguelands", "Un'Goro Crater", "Azshara" }

ns.FishDB = {
    -- { itemID, name (fallback), water, minimum skill (approx.), zones, note }
    -- water: "inland" (rivers, lakes), "coast" (sea), "school" (fish schools / pools), "both"
    fish = {
        { 6291, "Raw Brilliant Smallfish", "inland", 1, plus(STARTER, { "Loch Modan", "Westfall", "The Barrens", "Darkshore", "Silverpine Forest" }) },
        { 6303, "Raw Slitherskin Mackerel", "coast", 1, { "Durotar", "Teldrassil", "Darkshore", "Westfall", "Silverpine Forest", "The Barrens" } },
        { 6289, "Raw Longjaw Mud Snapper", "inland", 1, plus(STARTER, { "Loch Modan", "Westfall", "The Barrens", "Darkshore", "Silverpine Forest", "Redridge Mountains", "Stonetalon Mountains", "Ashenvale" }) },
        { 6317, "Raw Loch Frenzy", "inland", 1, { "Loch Modan" } },
        { 6361, "Raw Rainbow Fin Albacore", "coast", 1, LOW_COAST },
        { 6522, "Deviate Fish", "inland", 1, { "The Barrens" }, "Oases around the Wailing Caverns" },
        { 21071, "Raw Sagefish", "school", 1, { "Westfall", "Loch Modan", "The Barrens", "Silverpine Forest", "Darkshore", "Redridge Mountains", "Ashenvale", "Wetlands", "Hillsbrad Foothills", "Stonetalon Mountains" }, "Sagefish schools" },
        { 6308, "Raw Bristle Whisker Catfish", "inland", 55, { "Redridge Mountains", "Duskwood", "Wetlands", "Hillsbrad Foothills", "Ashenvale", "Stonetalon Mountains", "The Barrens", "Loch Modan", "Westfall", "Darkshore", "Silverpine Forest", "Thousand Needles", "Alterac Mountains" } },
        { 6358, "Oily Blackmouth", "both", 55, { "Westfall", "Darkshore", "The Barrens", "Wetlands", "Silverpine Forest", "Hillsbrad Foothills", "Stranglethorn Vale", "Desolace", "Durotar" }, "Coast and Oily Blackmouth schools" },
        { 6359, "Firefin Snapper", "both", 55, { "Westfall", "Darkshore", "The Barrens", "Wetlands", "Hillsbrad Foothills", "Stranglethorn Vale", "Desolace", "Dustwallow Marsh", "Arathi Highlands" }, "Coast and Firefin Snapper schools" },
        { 6362, "Raw Rockscale Cod", "coast", 130, { "Hillsbrad Foothills", "Desolace", "Stranglethorn Vale", "Arathi Highlands", "Dustwallow Marsh", "Wetlands", "Thousand Needles", "Swamp of Sorrows" } },
        { 8365, "Raw Mithril Head Trout", "inland", 130, { "Arathi Highlands", "Alterac Mountains", "Desolace", "Dustwallow Marsh", "Stranglethorn Vale", "Swamp of Sorrows", "Hillsbrad Foothills", "Duskwood", "Wetlands", "Ashenvale", "Stonetalon Mountains" } },
        { 21153, "Raw Greater Sagefish", "school", 130, { "Arathi Highlands", "Desolace", "Dustwallow Marsh", "Stranglethorn Vale", "Swamp of Sorrows", "Thousand Needles", "Alterac Mountains", "Hillsbrad Foothills" }, "Greater Sagefish schools" },
        { 4603, "Raw Spotted Yellowtail", "coast", 205, plus(HIGH_COAST, { "Dustwallow Marsh", "Desolace" }) },
        { 13754, "Raw Glossy Mightfish", "coast", 205, HIGH_COAST },
        { 13756, "Raw Summer Bass", "coast", 205, HIGH_COAST, "Summer only" },
        { 13755, "Raw Winter Squid", "coast", 205, HIGH_COAST, "Winter only" },
        { 13758, "Raw Redgill", "inland", 205, plus(HIGH_INLAND, { "Burning Steppes" }) },
        { 13759, "Raw Nightfin Snapper", "inland", 205, plus(HIGH_INLAND, { "Winterspring", "Eastern Plaguelands" }), "Night only" },
        { 13760, "Raw Sunscale Salmon", "inland", 205, plus(HIGH_INLAND, { "Winterspring", "Eastern Plaguelands" }), "Day only" },
        { 13422, "Stonescale Eel", "school", 205, plus(HIGH_COAST, { "Swamp of Sorrows" }), "Stonescale Eel swarms" },
        { 13757, "Lightning Eel", "school", 205, { "Azshara", "Feralas", "Tanaris", "The Hinterlands" }, "Schools in high-level seas" },
        { 13889, "Raw Whitescale Salmon", "inland", 330, { "Winterspring", "Eastern Plaguelands", "Deadwind Pass", "Burning Steppes" } },
        { 13888, "Darkclaw Lobster", "coast", 330, { "Feralas", "Azshara", "Tanaris", "The Hinterlands" } },
        { 13893, "Large Raw Mightfish", "coast", 330, { "Azshara", "Feralas", "Tanaris" } },
    },
    -- fishing skill a zone needs before fish stop getting away (approx., classic values)
    zoneSkill = {
        ["Elwynn Forest"] = 1, ["Dun Morogh"] = 1, ["Teldrassil"] = 1, ["Durotar"] = 1, ["Mulgore"] = 1,
        ["Tirisfal Glades"] = 1, ["Stormwind City"] = 1, ["Ironforge"] = 1, ["Darnassus"] = 1,
        ["Orgrimmar"] = 1, ["Thunder Bluff"] = 1, ["Undercity"] = 1, ["Zephras Isle"] = 1,
        ["The Barrens"] = 55, ["Darkshore"] = 55, ["Loch Modan"] = 55, ["Silverpine Forest"] = 55, ["Westfall"] = 55,
        ["Redridge Mountains"] = 130, ["Ashenvale"] = 130, ["Duskwood"] = 130, ["Hillsbrad Foothills"] = 130,
        ["Stonetalon Mountains"] = 130, ["Wetlands"] = 130, ["Thousand Needles"] = 130,
        ["Alterac Mountains"] = 205, ["Arathi Highlands"] = 205, ["Desolace"] = 205, ["Dustwallow Marsh"] = 205,
        ["Stranglethorn Vale"] = 205, ["Swamp of Sorrows"] = 205, ["Badlands"] = 205,
        ["Feralas"] = 205, ["Felwood"] = 205, ["Moonglade"] = 205, ["The Hinterlands"] = 205, ["Un'Goro Crater"] = 205,
        ["Tanaris"] = 330, ["Azshara"] = 330, ["Western Plaguelands"] = 330, ["Burning Steppes"] = 330,
        ["Deadwind Pass"] = 330, ["Silithus"] = 330, ["Winterspring"] = 330,
        ["Eastern Plaguelands"] = 425,
    },
}
