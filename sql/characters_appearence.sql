-- جدول مظهر الشخصيات لمورد w_creators
-- شغّل هذا الملف مرة واحدة على قاعدة البيانات.
-- ملاحظة: هذا جدول خاص بالمورد ولا يمسّ جداول شخصيات إطار العمل إطلاقًا،
-- لذا شخصيات اللاعبين الحالية آمنة تمامًا.

CREATE TABLE IF NOT EXISTS `characters_appearence` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `charid` VARCHAR(64) NOT NULL,          -- هوية الشخصية من إطار العمل (vorp charIdentifier / rsg-qbr citizenid)
    `isMale` TINYINT(1) NOT NULL DEFAULT 1,
    `name` VARCHAR(60) DEFAULT NULL,
    `age` INT DEFAULT NULL,
    `faceFeatures` LONGTEXT DEFAULT NULL,
    `overlays` LONGTEXT DEFAULT NULL,
    `components` LONGTEXT DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `charid` (`charid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- ترقية جدول موجود مسبقًا (شغّل ما تحتاجه فقط):
-- ---------------------------------------------------------------------
-- إن كان لديك عمود citizenid قديم وتريد تحويله إلى charid:
--   ALTER TABLE `characters_appearence` CHANGE COLUMN `citizenid` `charid` VARCHAR(64) NOT NULL;

-- إضافة الأعمدة الجديدة إن لم تكن موجودة:
ALTER TABLE `characters_appearence` ADD COLUMN IF NOT EXISTS `charid` VARCHAR(64) NOT NULL;
ALTER TABLE `characters_appearence` ADD COLUMN IF NOT EXISTS `name` VARCHAR(60) DEFAULT NULL;
ALTER TABLE `characters_appearence` ADD COLUMN IF NOT EXISTS `age` INT DEFAULT NULL;
ALTER TABLE `characters_appearence` ADD COLUMN IF NOT EXISTS `components` LONGTEXT DEFAULT NULL;
