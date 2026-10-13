fx_version 'cerulean'
games { 'rdr3' }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

author 'BCC Team'

description 'Advanced Housing Script: A comprehensive and customizable system for managing player houses.'

shared_scripts {
    'configs/*.lua',
    'locale.lua',
    'languages/*.lua',
    'shared/init.lua'
}

-- PolyZone is optional: to draw house outlines, start the PolyZone resource and
-- add '@PolyZone/client.lua' as the first client script. Without it the built-in
-- polygon check is used.
client_scripts {
    'client/feather/init.lua',
    'client/feather/toolkit.lua',
    'client/feather/menu_v2.lua',
    'client/functions.lua',
    'client/MainHousing.lua',
    'client/propertyCheck.lua',
    'client/furnitureSpawning.lua',
    'client/furnitureVendor.lua',
    'client/MenuSetup/adminManagementMenu.lua',
    'client/MenuSetup/buyHouse.lua',
    'client/MenuSetup/createHouseMenu.lua',
    'client/MenuSetup/furnitureMenu.lua',
    'client/MenuSetup/manageHouseMenu.lua',
    'client/MenuSetup/npcAgents.lua',
    'client/MenuSetup/sellHouse.lua',
}

server_scripts {
    '@feather-mysql/lib/DB.lua',
    'server/feather/init.lua',
    'server/feather/authority.lua',
    'server/feather/jobs.lua',
    'server/feather/property.lua',
    'server/feather/economy.lua',
    'server/feather/contracts.lua',
    'server/feather/inventory.lua',
    'server/helpers/functions.lua',
    'server/helpers/propertyDocuments.lua',
    'server/services/*.lua',
    'server/main.lua'
}
ui_page {
    "ui/index.html"
}

files {
    "ui/index.html",
    "ui/assets/*",
    'stream/Siddin3.ymap',
    'stream/Siddin4.ymap',
}

dependencies {
    'feather-mysql',
    'feather-core',
    'feather-character',
    'feather-notify',
    'feather-toolkit',
    'feather-menu-v2',
    'feather-inventory',
    'feather-economy',
    'feather-contracts',
    'feather-property',
    'feather-authority',
    'feather-jobs',
    'feather-routing',
    'bcc-doorlocks'
}

version '3.0.0'
