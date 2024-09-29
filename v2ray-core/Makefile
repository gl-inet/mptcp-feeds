# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2021-2022 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=v2ray-core

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/luochongjun/mptcptun.git
PKG_SOURCE_DATE:=2024-01-04
PKG_SOURCE_VERSION:=52c8e7080742dc9b422f583b9335dca7e95854e3
PKG_MIRROR_HASH:=60b183f284817eb45bb5848dba06f5f4054e58991e006327c90407228a30c560

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/v2fly/v2ray-core/v5
GO_PKG_BUILD_PKG:=$(GO_PKG)/main
#GO_PKG_TAGS:=gc
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG).build=OpenWrt \
	$(GO_PKG).version=$(PKG_VERSION)

PKG_BUILD_DEPENDS:=lua/host luajit2/host

define NGX_LUAC
if [ "$(CONFIG_NGINX_USE_LUAJIT)" == "y" ];then \
	$(STAGING_DIR_HOSTPKG)/bin/luajit_host.sh $(1) $(2); \
else \
	$(STAGING_DIR_HOSTPKG)/bin/luac -o $(1) $(2); \
fi
endef

include $(INCLUDE_DIR)/package.mk
include ../lang/golang/golang-package.mk

define Package/v2ray/template
  TITLE:=A platform for building proxies to bypass network restrictions
  SECTION:=net
  CATEGORY:=Network
  URL:=https://www.v2fly.org
endef

define Package/v2ray-core
  $(call Package/v2ray/template)
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +kmod-ipt-tproxy  +bind-dig
endef

define Package/v2ray-example
  $(call Package/v2ray/template)
  TITLE+= (example configs)
  DEPENDS:=v2ray-core
  PKGARCH:=all
endef

define Package/v2ray-extra
  $(call Package/v2ray/template)
  TITLE+= (extra resources)
  DEPENDS:=v2ray-core
  PKGARCH:=all
endef

define Package/v2ray/description
  Project V is a set of network tools that help you to build your own computer network.
  It secures your network connections and thus protects your privacy.
endef

define Package/v2ray-core/description
  $(call Package/v2ray/description)
endef

define Package/v2ray-example/description
  $(call Package/v2ray/description)

  This includes example configuration files for v2ray-core.
endef

define Package/v2ray-extra/description
  $(call Package/v2ray/description)

  This includes extra resources for v2ray-core.
endef

define Package/v2ray-core/conffiles
/etc/config/mptun
/etc/mptun/
endef

define Package/v2ray-core/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/main $(1)/usr/bin/mptun
	$(INSTALL_BIN) $(CURDIR)/files/mptcp-proxy.nft $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/proxy-route.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/get_mplinkip.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/get_mpsrv_delay.sh $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/mptun/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/release/config/config.json $(1)/etc/mptun/
	$(INSTALL_DATA) $(CURDIR)/files/basic.json $(1)/etc/mptun/
	$(INSTALL_DATA) $(CURDIR)/files/dnsmasq.conf.mptun $(1)/etc/

	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) $(CURDIR)/files/mptun.conf $(1)/etc/config/mptun
	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_BIN) $(CURDIR)/files/mptun.init $(1)/etc/init.d/mptun

	$(INSTALL_DIR) $(1)/lib/functions/
	$(INSTALL_BIN) $(CURDIR)/files/mptun.sh $(1)/lib/functions/

	$(INSTALL_DIR) $(1)/usr/lib/oui-httpd/rpc
	$(CP) $(CURDIR)/files/mptun.lua $(1)/usr/lib/oui-httpd/rpc/mptun
	$(call NGX_LUAC,$(1)/usr/lib/oui-httpd/rpc/mptun,$(1)/usr/lib/oui-httpd/rpc/mptun)

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/51-aw_upgrade_compat.sh  $(1)/etc/uci-defaults
endef

define Package/v2ray-example/install
	$(INSTALL_DIR) $(1)/etc/mptun/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/release/config/vpoint_socks_vmess.json $(1)/etc/mptun/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/release/config/vpoint_vmess_freedom.json $(1)/etc/mptun/
endef

define Package/v2ray-extra/install
	$(INSTALL_DIR) $(1)/usr/share/mptun/
	$(CP) $(PKG_BUILD_DIR)/release/extra/* $(1)/usr/share/mptun/
endef

$(eval $(call BuildPackage,v2ray-core))
$(eval $(call BuildPackage,v2ray-example))
$(eval $(call BuildPackage,v2ray-extra))
