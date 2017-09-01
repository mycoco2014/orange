const VueConfig = {
    delimiters: ['${', '}']
};

new Vue(
    Object.assign(VueConfig, {
        el: '#page-wrapper',
        data: {
            enable: 0,
            message: 'Oh my app',
            upstreams: [],
            servers: {
                primary: [],
                backup: []
            },
            selectUpstream: '',
            errMessage: null,
            confChanged: false,
            pluginEnable: 0
        },
        methods:  {
            showTipDialog: function (title, content) {
                toastr.options = {
                    "closeButton": true,
                    "debug": false,
                    "progressBar": true,
                    "positionClass": "toast-top-right",
                    "onclick": null,
                    "showDuration": "400",
                    "hideDuration": "3000",
                    "timeOut": "7000",
                    "extendedTimeOut": "3000",
                    "showEasing": "swing",
                    "hideEasing": "linear",
                    "showMethod": "fadeIn",
                    "hideMethod": "fadeOut"
                };
                toastr.success(content, title || "提示");
            },
            showErrorTip: function (title, content) {
                toastr.options = {
                    "closeButton": true,
                    "debug": false,
                    "progressBar": true,
                    "positionClass": "toast-top-right",
                    "onclick": null,
                    "showDuration": "400",
                    "hideDuration": "10000",
                    "timeOut": "7000",
                    "extendedTimeOut": "10000",
                    "showEasing": "swing",
                    "hideEasing": "linear",
                    "showMethod": "fadeIn",
                    "hideMethod": "fadeOut"
                };
                toastr.error(content,title || "错误提示");
            },
            changePeerStatus: function(item){
                item.down = !item.down;
                this.confChanged = true;
            },
            initUpstream: function() {
                // 获取状态,以及服务列表
                this.$http.get('/upstream_conf/status').then(function(resp){
                    if(resp.body.success){
                        this.upstreams.splice(0);
                        this.pluginEnable = resp.body.data.enable;
                        var upstreams = resp.body.data['upstreams'];
                        for(var ix = 0 ; ix < upstreams.length; ix++){
                            this.upstreams.push(upstreams[ix]);
                        }
                        if (this.upstreams.length > 0) {
                            this.getUpstreamServerList(this.upstreams[0]);
                        }
                    } else {
                        this.upstreams.splice(0);
                    }
                }, function(err){
                    this.showErrorTip('错误提示', err || '获取upstream block列表失败');
                });
            },
            getUpstreamServerList: function(item) {
                this.selectUpstream = item;
                this.confChanged = false;
                this.$http.get('/upstream_conf/upstream?name=' + item).then(function(resp){
                    if(resp.body.success){
                        this.servers.primary.splice(0);
                        this.servers.backup.splice(0);
                        for(var ix = 0 ; ix < resp.body.data['primary'].length; ix++){
                            var tmp = resp.body.data['primary'][ix];
                            if(typeof tmp['down'] === 'undefined') {
                                tmp['down'] = false;
                            }
                            this.servers.primary.push(tmp);
                        }
                        for(var ix = 0 ; ix < resp.body.data['backup'].length; ix++){
                            var tmp = resp.body.data['backup'][ix];
                            if(typeof tmp['down'] === 'undefined') {
                                tmp['down'] = false;
                            }
                            this.servers.backup.push(tmp);
                        }
                    } else {
                        this.servers.primary.splice(0);
                        this.servers.backup.splice(0);
                    }
                }, function(err){
                    this.showErrorTip('错误提示', err || '获取upstream servers列表失败');
                });
            },
            updateUpstreamConf: function(){
                // 更新
                // /upstream_conf/upstream
                this.$http.post('/upstream_conf/upstream?name=' +  this.selectUpstream, this.servers).then(function(resp){
                    if(resp.body.success){
                        this.confChanged = false;
                    } else {
                        this.showErrorTip('错误提示', '更新upstream servers status\r\n' + resp.body.message || '');
                    }
                }, function(err){
                    this.showErrorTip('错误提示', err || '更新upstream servers列表失败');
                });
            },
            enableUpstreamPlugin: function (enable) {
                var data = 'enable=' + enable.toString();
                this.$http.post('/upstream_conf/enable',data, {
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
                    }
                }).then(function(resp){
                    if(resp.body.success){
                        if(this.pluginEnable === 0) {
                            this.pluginEnable = 1;
                        } else {
                            this.pluginEnable = 0 ;
                        }
                        this.showTipDialog('提示','操作成功');
                    } else {
                        this.showErrorTip('错误提示', '操作失败\r\n' + resp.body.message || '');
                    }
                }, function(err) {
                    this.showErrorTip('错误提示', err || '操作失败');
                });
            },

            startSyncUpstreamPlugin: function() {
                this.$http.post('/upstream_conf/sync').then(function(resp) {
                    if (resp.body.success) {
                        // ui 重新加载配置
                        this.showTipDialog("提示", "同步配置成功");
                    }
                }, function(err) {
                    this.showErrorTip("错误提示", err || "同步配置发生错误");
                })
            },
            testClick: function(){
                this.showErrorTip("提示", "222同步配置发生错误");
            },
            syncUpstreamPlugin: function(){
                var that = this;
                this.$http.get('/upstream_conf/fetch_config').then(function(resp){
                    if(resp.body.success){
                        var d = dialog({
                            title: '确定要从存储中同步配置吗?',
                            top: 10,
                            width: 680,
                            content: '<pre id="preview_plugin_config"><code></code></pre>',
                            modal: true,
                            button: [{
                                value: '取消'
                            }, {
                                value: '确定同步',
                                autofocus: false,
                                callback: function () {
                                    that.startSyncUpstreamPlugin();
                                }
                            }]
                        });
                        d.show();
                        $("#preview_plugin_config code").text(JSON.stringify(resp.body.data, null, 2));
                        $('pre code').each(function () {
                            hljs.highlightBlock($(this)[0]);
                        });
                    } else {
                        this.showErrorTip("错误提示", "同步配置发生错误\r\n" + resp.body.message || '' );
                    }
                }, function(err) {
                    this.showErrorTip("错误提示", "同步配置发生错误\r\n" + err || '' );
                });
            }
        },
        mounted: function() {
            this.initUpstream();
        }
    })
);
