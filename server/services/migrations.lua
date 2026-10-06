-- bcc-stables owns only gameplay state. Ownership, model and metadata live in
-- feather-assets; money in feather-economy; saddlebag items in feather-inventory.
-- Applied migrations are checksummed. Never edit one; add a new migration.

StablesMigrations = {}

local definitions = {
    {
        id = '001_stables_horses',
        statements = {
            -- One row per horse asset, never deleted: feather-inventory's saddlebag
            -- foreign key cascades on delete. Retired horses keep their row.
            [[CREATE TABLE IF NOT EXISTS `bcc_stables_horses` (
                `asset_id` CHAR(36) NOT NULL,
                `xp` INT UNSIGNED NOT NULL DEFAULT 0,
                `health` TINYINT UNSIGNED NOT NULL DEFAULT 100,
                `stamina` TINYINT UNSIGNED NOT NULL DEFAULT 100,
                `writhe` TINYINT(1) NOT NULL DEFAULT 0,
                `captured` TINYINT(1) NOT NULL DEFAULT 0,
                `born_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`asset_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
            -- The horse a character calls from a stable. A selection is only a
            -- preference; ownership is rechecked with Assets on every use.
            [[CREATE TABLE IF NOT EXISTS `bcc_stables_selection` (
                `character_id` CHAR(36) NOT NULL,
                `asset_id` CHAR(36) NOT NULL,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`character_id`),
                KEY `idx_stables_selection_asset` (`asset_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]]
        }
    },
    {
        id = '002_stables_orders',
        statements = {
            -- Workflow receipts for every money-moving operation. Never balances.
            [[CREATE TABLE IF NOT EXISTS `bcc_stables_orders` (
                `order_id` CHAR(36) NOT NULL,
                `character_id` CHAR(36) NOT NULL,
                `kind` VARCHAR(24) NOT NULL,
                `state` VARCHAR(24) NOT NULL,
                `payload_json` LONGTEXT NOT NULL,
                `asset_id` CHAR(36) NULL,
                `transaction_id` CHAR(36) NULL,
                `last_error` VARCHAR(64) NULL,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`order_id`),
                KEY `idx_stables_orders_character` (`character_id`,`state`),
                CONSTRAINT `chk_stables_order_state` CHECK (`state` IN
                    ('pending','paid','fulfilled','rejected','review'))
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]]
        }
    },
    {
        id = '003_stables_horses_inventory_collation',
        statements = {
            -- feather-inventory's saddlebag foreign key column is created with the
            -- `inventory` table's collation (utf8mb4_unicode_ci). MariaDB only accepts
            -- a foreign key between columns of the same collation (ER_CANT_CREATE_TABLE).
            [[ALTER TABLE `bcc_stables_horses`
                MODIFY `asset_id` CHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL]]
        }
    },
    {
        id = '004_stables_order_resolution',
        statements = {
            -- How staff closed an order by hand (StablesOrdersResolve).
            [[ALTER TABLE `bcc_stables_orders`
                ADD COLUMN IF NOT EXISTS `resolution` VARCHAR(255) NULL AFTER `last_error`,
                ADD COLUMN IF NOT EXISTS `resolved_at` TIMESTAMP NULL AFTER `resolution`]]
        }
    }
}
StablesMigrations.Count = #definitions

local function Hash(value)
    local hash = 2166136261
    for index = 1, #value do
        hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
    end
    return ('fnv1a32:%08x'):format(hash)
end

function StablesMigrations.Run()
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_stables_schema_migrations` (
            `id` VARCHAR(100) NOT NULL,
            `checksum` VARCHAR(64) NOT NULL,
            `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
    local applied = 0
    for _, migration in ipairs(definitions) do
        local checksum = Hash(table.concat(migration.statements, '\n-- next statement --\n'))
        local row = DB.one('SELECT `checksum` FROM `bcc_stables_schema_migrations` WHERE `id`=?', migration.id)
        if row and row.checksum ~= checksum then
            return StablesCore.Err('migration_checksum_mismatch', 'An applied bcc-stables migration changed.', {
                migrationId = migration.id
            })
        end
        if not row then
            for _, statement in ipairs(migration.statements) do
                DB.exec(statement)
            end
            DB.insert('INSERT INTO `bcc_stables_schema_migrations` (`id`,`checksum`) VALUES (?,?)',
                migration.id, checksum)
            applied = applied + 1
        end
    end
    return StablesCore.Ok({ total = #definitions, applied = applied })
end
