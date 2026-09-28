{
	email @EMAIL@

	# 证书与 ACME:默认走 Let's Encrypt 正式环境
	# (需要 80/443 从公网可达,且域名 A/AAAA 记录指向本机)
@ACME_CA_LINE@
	# 管理接口只监听本机,Caddy 自更新/重载用
	admin 127.0.0.1:2019
}

# 公共响应头与压缩(在每个 handle 里 import,保证只作用于该路由)
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
#
# 路由结构(handle 组互斥,路径 matcher 优先于兜底 handle):
#   /healthz /health → 直接回 ok(探活,不经过 Hermes)
#   /v1/*            → 127.0.0.1:@API_PORT@  (OpenAI 兼容 API,可关闭)
#   其它             → 127.0.0.1:@DASH_PORT@ (Web 管理面板)
# ============================================================
@DOMAIN@ {
	# 健康检查(用于监控/探活)
	handle /healthz {
		respond "ok" 200
	}
	handle /health {
		respond "ok" 200
	}

@API_BLOCK@
	# 其余全部交给 Web 管理面板
	# dashboard.public_url=https://@DOMAIN@ 且面板绑回环,Caddy 从回环反代 ——
	# 回环代理被 Hermes 自动信任,无需放宽 trusted_proxies。
	handle {
		import hermes_common
		reverse_proxy 127.0.0.1:@DASH_PORT@
	}

	log {
		output file @LOG_DIR@/@DOMAIN@.access.log {
			roll_size 20MiB
			roll_keep 5
			roll_keep_for 168h
		}
		format console
	}
}
