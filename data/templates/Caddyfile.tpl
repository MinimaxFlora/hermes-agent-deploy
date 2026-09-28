{
	email @EMAIL@

	# 证书与 ACME:默认走 Let's Encrypt 正式环境
	# (需要 80/443 从公网可达,且域名 A/AAAA 记录指向本机)
@ACME_CA_LINE@
	# 管理接口只监听本机,Caddy 自更新/重载用
	admin 127.0.0.1:2019
}

# 公共响应头与压缩
(hermes_common) {
	encode zstd gzip
	header {
		-Server
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		X-Frame-Options "SAMEORIGIN"
	}
}

# ============================================================
# Hermes Agent 对外入口 —— 由 hermes-vps 生成,勿手工大改
# 生成时间: @GENERATED_AT@
# ============================================================
@DOMAIN@ {
	import hermes_common

	# 健康检查(不经过 Hermes,用于探活/监控)
	@health path /healthz /health
	respond @health "ok" 200

@API_BLOCK@
	# 其余全部交给 Web 管理面板(127.0.0.1:@DASH_PORT@)
	# dashboard.public_url=https://@DOMAIN@,绑定回环,Caddy 从回环反代 —— 官方推荐姿势
	# WebSocket / SSE 流式输出 Caddy 默认即支持,无需额外 transport 配置
	reverse_proxy 127.0.0.1:@DASH_PORT@

	log {
		output file @LOG_DIR@/@DOMAIN@.access.log {
			roll_size 20MiB
			roll_keep 5
			roll_keep_for 168h
		}
		format console
	}
}
