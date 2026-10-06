-- bcc-stables item definitions for feather-inventory.
-- Safe to run more than once: existing items keep their IDs, stock and settings.
-- The brush and lantern are 'unique' so feather-inventory can track their
-- condition (durability). Apply once, then restart feather-inventory and bcc-stables.

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'horsebrush', 'Horse Brush', 'A brush used for grooming horses.', 5, 1, 1, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'tools'), 'item_item', 'unique'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'horsebrush');

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'oil_lantern', 'Oil Lantern', 'A portable light source.', 1, 1, 2, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'tools'), 'item_item', 'unique'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'oil_lantern');

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'consumable_haycube', 'Haycube', 'A compact cube of hay.', 10, 10, 1, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'provisions'), 'item_item', 'stack'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'consumable_haycube');

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'consumable_carrots', 'Carrots', 'An orange root vegetable commonly used in cooking.', 10, 10, 1, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'provisions'), 'item_item', 'stack'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'consumable_carrots');

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'consumable_horse_reviver', 'Horse Reviver', 'Curative compound for injured horse.', 3, 3, 1, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'medicine'), 'item_item', 'stack'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'consumable_horse_reviver');

INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'diamond', 'Diamond', 'A precious gemstone known for its brilliance and value.', 20, 20, 0, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'valuables'), 'item_item', 'stack'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'diamond');

-- consumable_apple usually exists already; only make sure it can be used.
UPDATE `items` SET `usable` = 1 WHERE `name` = 'consumable_apple';
