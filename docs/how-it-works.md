# 原理：slowgate 如何生效

一句话：**在运行时把 `curl_easy_setopt` 这个函数劫道到我们自己的实现里，改掉其中两个参数。**
CloudSync 闭源、libcurl 是系统库，两边都不能改，所以走的是 Linux 动态链接的一个正规特性。

## 1. 问题

```
syno-cloud-syncd ──调用──▶ curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1)
                                   │
                                   ▼
                            libcurl.so.4 里的真身
```

只要能在运行时插进这一次调用，就有机会改参数。

## 2. 前置知识：外部函数是怎么被找到的

编译期并不把外部函数的代码抄进来，只留一个空槽：

```
编译期：  call curl_easy_setopt    ← 只写"调这个名字"，地址留空
运行期：  ld.so（动态加载器）把所有 .so 装进进程，填上真实地址
```

填地址的规则很简单：**进程里有一个全局符号表，谁的名字先出现就用谁的**。

`LD_PRELOAD` 是一个环境变量，语义是：

> 加载器听着：这几个 .so **必须排在所有其他库之前**装进来。

于是同一个名字有两个提供者时，排在前面的赢——程序对这个名字的所有调用都会进我们的函数。

这条路要成立，需要两个前提（部署前已验证）：

1. 目标程序是**动态链接**的 —— 查 ELF 依赖里有 `libcurl.so.4`；
2. 那次调用**走动态符号表**（经 PLT 间接跳转，而非编译期写死地址）—— 符号表里存在
   `curl_easy_setopt` 这个待解析名字。

## 3. 为什么需要 wrapper，而不是 `export LD_PRELOAD`

环境变量只对**之后启动的子进程**生效。实测 CloudSync 包的 `cloud-sync-starter`
在 exec 守护进程时会清洗环境，在 `start.sh` 里 `export` 根本到不了目标进程
（daemon 的 `/proc/<pid>/ environ` 里没有它）。

所以把设置环境的时机推到不能再晚的一刻：

```
真二进制改名成   syno-cloud-syncd.real
原位置放一个脚本 syno-cloud-syncd：
        export LD_PRELOAD=...                     ← 在 exec 现场自己设置
        exec .../syno-cloud-syncd.real "$@"        ← 原地替换进程，环境 100% 由它交给真二进制
```

启动链：`start.sh → starter →（exec）wrapper →（exec）真 daemon`，中间谁清洗环境都拦不住。

## 4. slowgate.c 逐段

### 4.1 拿到原厂实现的地址

```c
dlsym(RTLD_NEXT, "curl_easy_setopt")
```

`dlsym` 按名字查函数地址；`RTLD_NEXT` 表示"**从我后面的库里找**"——跳过自己，
拿到 `libcurl.so.4` 的真身。若写成 `RTLD_DEFAULT`（从头找）会查到自己，无限递归。

### 4.2 签名必须和原函数完全一致

```c
int curl_easy_setopt(CURL *h, CURLoption opt, ...)
```

名字、参数、返回值都得对上，否则调用方一进来就栈错乱；`...` 表示它是变参函数。

### 4.3 分流：两个改写，其余原样转发

```c
unsigned type = ((unsigned)opt) / 10000;      /* curl.h 的选项编码约定 */

if (opt == 19 || opt == 20) {        /* LOW_SPEED_LIMIT / LOW_SPEED_TIME */
    (void)va_arg(ap, long);          /* 把调用方给的 1 和 300 读出来…丢掉 */
    rc = real_setopt(h, opt, 0L);    /* 改成 0 交给真函数 */
} else if (type == 3) {              /* 30000 段 = curl_off_t */
    long long v = va_arg(ap, long long);
    rc = real_setopt(h, opt, v);
} else if (type == 0) {              /* 0 段 = long */
    long v = va_arg(ap, long);
    ...
} else {                             /* 10000/20000/40000 段 = 指针 */
    void *v = va_arg(ap, void *);
    ...
}
```

两个关键点：

- **我们是"改单"不是"拒单"**。直接返回不往下传，调用方后续的 curl 调用会全部失效，进程直接废掉。
- **变参转发必须知道宽度**。`va_arg` 要求你声明读 8 字节还是 4 字节，读错一个，后面的参数全乱。
  curl.h 的选项编号 `值 / 10000` 正好是类型（0=long、10000=指针、20000=函数指针、
  30000=`curl_off_t`、40000=结构体指针），照着分派即可。

### 4.4 为什么 0 能关掉保护

curl 的判断是 `low_speed_limit != 0 时才检查低速`，所以把 limit 设为 0 = 整套机制不执行；
顺手把 time 也设 0 是双保险。

## 5. 生效范围

- `LD_PRELOAD` 是**进程级**变量，只影响被注入的这一个进程；
- libcurl 内部对自己的调用不走动态符号表（同库内直接跳转），不受影响，也不需要受影响；
- 上传速率、上传逻辑、服务端行为都不变——不会变快，只是不再被判定死亡。

## 6. 最小复现

仓库自带一个不碰真实机器的复现（`tests/`）：

```bash
make test
```

它构造一个假的 `curl_easy_setopt` 打印收到的值：

```
--- 不注入 ---    opt=19 LONG  value=1                     ← 原始值照常传到
--- 注入 shim --- opt=19 LONG  value=0                     ← 被改写
                  opt=30115 OFF_T value=7213216146         ← 其它选项分毫未动
```

## 7. 什么情况下这条路走不通

- 目标程序在**编译期**就把函数地址写死（不走动态符号表），劫不到；
- 目标程序是 **setuid/setgid 或带文件能力**的，加载器处于安全模式，会忽略 `LD_PRELOAD`；
- 依赖库在**编译期静态链进**目标程序（本例已排除：daemon 动态依赖 `libcurl.so.4`）。

`deploy.sh` 的失败分支会打印 `/proc/<pid>/status` 的 `Cap*` 字段，就是用来查第二条的。
