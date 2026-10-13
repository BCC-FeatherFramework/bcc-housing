local function daysInMonth(year, month)
    if month == 2 then
        local leapYear = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leapYear and 29 or 28
    end

    if month == 4 or month == 6 or month == 9 or month == 11 then
        return 30
    end

    return 31
end

-- Tables made before 3.0.0 named the character column after VORP (charidentifier,
-- identifier on the payout queue). Renames it to character_id, keeping the data.
local function renameCharacterColumn(tableName, oldName)
    local exists = tonumber(DB.value([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], tableName, oldName)) or 0
    if exists > 0 then
        local renamed, problem = pcall(DB.exec,
            ('ALTER TABLE `%s` CHANGE COLUMN `%s` `character_id` CHAR(36) NOT NULL'):format(tableName, oldName))
        print(renamed and ('[bcc-housing] database: %s.%s renamed to character_id'):format(tableName, oldName)
            or ('[bcc-housing] database: renaming %s.%s failed: %s'):format(tableName, oldName, tostring(problem)))
    end
end

local function getDefaultPurchasedAtFromTaxDay()
    local taxDay = tonumber(Config.TaxDay) or 1
    taxDay = math.max(1, math.min(taxDay, 31))

    local date = os.date("*t")
    local year = date.year
    local month = date.month - 1
    if month < 1 then
        month = 12
        year = year - 1
    end

    local day = math.min(taxDay, daysInMonth(year, month))
    return ("%04d-%02d-%02d 00:00:00"):format(year, month, day)
end

CreateThread(function()
    DB.awaitReady()
    -- Create the bcchousing table if it doesn't exist. Character columns hold Feather
    -- character UUIDs; bcchousing.character_id caches the holder, feather-property is the truth.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcchousing` (
            `character_id` CHAR(36) NOT NULL,
            `house_coords` LONGTEXT NOT NULL,
            `house_radius_limit` varchar(100) NOT NULL,
            `houseid` int NOT NULL AUTO_INCREMENT,
            `furniture` LONGTEXT NOT NULL DEFAULT 'none',
            `doors` LONGTEXT NOT NULL DEFAULT 'none',
            `allowed_ids` LONGTEXT NOT NULL DEFAULT 'none',
            `invlimit` varchar(50) NOT NULL DEFAULT 200,
            `player_source_spawnedfurn` varchar(50) NOT NULL DEFAULT 'none',
            `taxes_collected` varchar(50) NOT NULL DEFAULT 'false',
            `tax_amount` float NOT NULL DEFAULT 0,
            PRIMARY KEY `houseid` (`houseid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Add tpInt and tpInstance columns to bcchousing if they don't exist
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `tpInt` int(10) DEFAULT 0")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `tpInstance` int(10) DEFAULT 0")
	DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `uniqueName` VARCHAR(255) NOT NULL")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `ownershipStatus` ENUM('purchased', 'rented') NOT NULL DEFAULT 'purchased'")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `purchaseCurrencyType` TINYINT NOT NULL DEFAULT 0")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `inventory_current_stage` int(10) NOT NULL DEFAULT 0")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `poly_points` LONGTEXT NULL")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `poly_min_z` DOUBLE NULL")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `poly_max_z` DOUBLE NULL")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `property_deed` LONGTEXT NULL")
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `purchased_at` DATETIME NULL DEFAULT NULL")
    -- The house's feather-property property (see server/feather/property.lua).
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `property_id` CHAR(36) NULL DEFAULT NULL")
    -- Taxes paid ahead cover every due date up to this day (no money is kept here).
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `taxes_paid_until` DATE NULL DEFAULT NULL")
    -- The latest tax or rent obligation in feather-contracts (see server/feather/contracts.lua).
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `tax_obligation_id` CHAR(36) NULL DEFAULT NULL")
    local lastTaxProcessedColumnCount = tonumber(DB.value([[
        SELECT COUNT(*)
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'bcchousing'
          AND COLUMN_NAME = 'last_tax_processed_at'
    ]])) or 0
    local hadLastTaxProcessedColumn = lastTaxProcessedColumnCount > 0
    DB.exec("ALTER TABLE `bcchousing` ADD COLUMN IF NOT EXISTS `last_tax_processed_at` DATE NULL DEFAULT NULL")
    if not hadLastTaxProcessedColumn then
        DB.exec("UPDATE `bcchousing` SET `last_tax_processed_at` = CURDATE() WHERE `last_tax_processed_at` IS NULL")
    end
    DB.exec("UPDATE `bcchousing` SET `purchased_at` = ? WHERE `purchased_at` IS NULL", getDefaultPurchasedAtFromTaxDay())

    -- Create the bcchousinghotels table if it doesn't exist
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcchousinghotels` (
            `character_id` CHAR(36) NOT NULL,
            `hotels` LONGTEXT NOT NULL DEFAULT 'none',
            PRIMARY KEY (`character_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Agent payouts: a retry queue for sales back to the agent (see sellHouse.lua).
    -- Economy holds the money; a row here only records a payout until it is paid.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcchousing_transactions` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `houseid` int(11) NOT NULL,
            `character_id` CHAR(36) NOT NULL,
            `amount` DECIMAL(14,2) NOT NULL,
            `currency` varchar(16) NOT NULL DEFAULT 'dollars',
            `reason` varchar(64) NOT NULL DEFAULT 'housing.sold_to_agent',
            `idempotency_key` varchar(128) NOT NULL,
            `status` varchar(16) NOT NULL DEFAULT 'pending',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_bcchousing_payout_key` (`idempotency_key`),
            KEY `idx_bcchousing_payout_pending` (`status`, `character_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- One row per character and hotel: the key of that room's feather-inventory container.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcchousing_hotel_rooms` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `hotel_id` int(11) NOT NULL,
            `character_id` CHAR(36) NOT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_bcchousing_hotel_room` (`hotel_id`, `character_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcchousing_ownedfurniture` (
            `character_id` CHAR(36) NOT NULL,
            `items` LONGTEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (`character_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    renameCharacterColumn('bcchousing', 'charidentifier')
    renameCharacterColumn('bcchousinghotels', 'charidentifier')
    renameCharacterColumn('bcchousing_transactions', 'identifier')
    renameCharacterColumn('bcchousing_hotel_rooms', 'charidentifier')
    renameCharacterColumn('bcchousing_ownedfurniture', 'charidentifier')

    -- Furniture spawned before a restart belongs to nobody now.
    DB.exec("UPDATE `bcchousing` SET `player_source_spawnedfurn` = 'none' WHERE `player_source_spawnedfurn` <> 'none'")

    DbUpdated = true

    print("Database tables for \x1b[35m\x1b[1m*bcc-housing*\x1b[0m created or updated \x1b[32msuccessfully\x1b[0m.")
end)
