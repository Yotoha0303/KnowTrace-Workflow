# ISSUE-S3-003：Python 响应头大小写导致 metrics 误判

- 范围：核心验收脚本。
- 状态：已关闭。
- 修复 commit：`6b7db23`。
- 影响：服务实际正常，但验收脚本报 `metrics Content-Type 不正确`。

## 证据

携带正确 token 手工请求得到：

```text
HTTP/1.1 200 OK
content-type: text/plain; version=0.0.4; charset=utf-8
```

未授权请求和公网 Nginx 路径均返回 404。

## 根因

HTTP 头字段名不区分大小写，但脚本把 `response.headers.items()` 转成普通字典后，只读取 `Content-Type`。实际键为小写 `content-type`。

## 修复

统一把所有响应头键转换为小写，再读取 `content-type`。

## 回归

核心验收完整通过，受保护指标接口与公网阻断均通过。

## 经验

协议语义不区分大小写时，测试代码也必须规范化；不能为了让检查通过而改变正确的服务响应头。
