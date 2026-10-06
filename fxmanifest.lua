fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

game 'rdr3'
lua54 'yes'
author 'BCC Team'

shared_scripts {
    'config/*.lua',
    'locale.lua',
    'languages/*.lua'
}

-- Each file is listed once: a file named here and also matched by a glob loads twice.
client_scripts {
    'client/feather/init.lua',
    'client/dataview.lua',
    'client/main.lua',
    'client/horseinfo.lua',
    'client/menus/horse_info.lua'
}

server_scripts {
    '@feather-mysql/lib/DB.lua',
    'server/feather/init.lua',
    'server/feather/assets.lua',
    'server/feather/economy.lua',
    'server/feather/inventory.lua',
    'server/feather/jobs.lua',
    'server/services/migrations.lua',
    'server/services/horses.lua',
    'server/services/orders.lua',
    'server/main.lua',
    'server/items.lua',
    'server/commands.lua',
    'server/chat_suggestions.lua',
    'server/tests.lua'
}

ui_page {
    'ui/index.html'
}

files {
    'ui/index.html',
    'ui/js/*.*',
    'ui/css/*.*',
    'ui/fonts/*.*',
    'ui/img/*.*'
}

dependencies {
    'feather-mysql',
    'feather-core',
    'feather-character',
    'feather-notify',
    'feather-menu-v2',
    'feather-assets',
    'feather-economy',
    'feather-inventory',
    'feather-jobs'
}

version '2.0.0'
