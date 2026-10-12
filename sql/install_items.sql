-- bcc-housing item definitions for feather-inventory.
-- Safe to run more than once: existing items keep their IDs and settings.
-- Apply once, then restart feather-inventory and bcc-housing.

-- Property deed: a display copy of a house's ownership (metadata carries the house
-- and feather-property IDs). Unique, so each deed keeps its own metadata.
INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'property_deed', 'Property Deed', 'A deed for a house. Ownership is recorded by the land office.', 10, 1, 0.1, 0,
    (SELECT `id` FROM `categories` WHERE `name` = 'documents'), 'item_item', 'unique'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'property_deed');

-- Furniture book: opens the list of furniture the character owns.
INSERT INTO `items`
    (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`, `weight`, `usable`, `category_id`, `type`, `instance_mode`)
SELECT 'furniture_book', 'Furniture Book', 'Lists the furniture you own and lets you place it in your house.', 1, 1, 0.2, 1,
    (SELECT `id` FROM `categories` WHERE `name` = 'documents'), 'item_item', 'stack'
WHERE NOT EXISTS (SELECT 1 FROM `items` WHERE `name` = 'furniture_book');
