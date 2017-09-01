### 动态配置upstream模块

使用之前需要在OpenResty配置文件中添加以下配置项：


- plugins列表在 conf/orange.conf文件中配置
- 如果不需要设置handler,需要删除upstream_conf里面的handle

