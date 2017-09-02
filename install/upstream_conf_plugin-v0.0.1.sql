-- upstream conf 表
CREATE TABLE `upstream_conf` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `key` varchar(255) NOT NULL DEFAULT '',
  `value` varchar(2000) NOT NULL DEFAULT '',
  `type` varchar(32) DEFAULT '0',
  `op_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_key` (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;


INSERT INTO `upstream_conf` (`id`, `key`, `value`, `type`, `op_time`)
VALUES
    (1,'1','{}','meta','2017-09-03 11:11:11');


