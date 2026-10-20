#define _GNU_SOURCE
/*
 * cs_lowspeed.so — 关闭 libcurl 的低速保护（CURLOPT_LOW_SPEED_LIMIT / _TIME）
 *
 * 用于 WebDAV 客户端（如 Synology CloudSync）上传时，服务端先收完整份文件再转传上游，
 * 导致「收完 → 回响应」之间出现长静默、被 curl 判为传输死亡（curl 28, Operation too slow）。
 *
 * 只拦 curl_easy_setopt（动态符号，经 PLT 进入），其余选项原样转发。
 * 选项编码约定（curl.h）：0=LONG, 10000=OBJECTPOINT, 20000=FUNCTIONPOINT,
 *                        30000=OFF_T(curl_off_t), 40000=BLOB —— 按 值/10000 分派。
 *
 * 构建：make        自测：make test
 */
#include <stdarg.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void CURL;
typedef int CURLoption;

#define CURLOPT_LOW_SPEED_LIMIT 19
#define CURLOPT_LOW_SPEED_TIME  20

static int (*real_setopt)(CURL *, CURLoption, ...);
static int announced;

static void lazy(void)
{
    if (!real_setopt)
        *(void **)(&real_setopt) = dlsym(RTLD_NEXT, "curl_easy_setopt");
}

__attribute__((constructor))
static void shim_init(void)
{
    lazy();
}

int curl_easy_setopt(CURL *h, CURLoption opt, ...)
{
    va_list ap;
    unsigned type = ((unsigned)opt) / 10000;
    int rc;

    va_start(ap, opt);

    if (opt == CURLOPT_LOW_SPEED_LIMIT || opt == CURLOPT_LOW_SPEED_TIME) {
        /* 消费调用方传入的值，改成 0 —— curl 规定 limit=0 时低速检查整套不执行 */
        (void)va_arg(ap, long);
        lazy();
        if (!announced) {
            announced = 1;
            (void)!write(2, "cs_lowspeed: low-speed guard disabled\n", 38);
        }
        rc = real_setopt(h, opt, 0L);
    } else if (type == 3) {                 /* OFF_T: curl_off_t */
        long long v = va_arg(ap, long long);
        lazy();
        rc = real_setopt(h, opt, v);
    } else if (type == 0) {                 /* LONG / VALUES */
        long v = va_arg(ap, long);
        lazy();
        rc = real_setopt(h, opt, v);
    } else {                                /* OBJECTPOINT / FUNCTIONPOINT / BLOB */
        void *v = va_arg(ap, void *);
        lazy();
        rc = real_setopt(h, opt, v);
    }

    va_end(ap);
    return rc;
}
