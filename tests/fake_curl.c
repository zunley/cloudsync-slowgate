/* 假的 curl_easy_setopt：按 curl.h 的选项编码规则回放收到的值，供变参转发自测 */
#include <stdarg.h>
#include <stdio.h>

int curl_easy_setopt(void *h, int opt, ...)
{
    va_list ap;
    unsigned type = ((unsigned)opt) / 10000;
    (void)h;
    va_start(ap, opt);
    if (type == 3) {
        long long v = va_arg(ap, long long);
        printf("opt=%d OFF_T value=%lld\n", opt, v);
    } else if (type == 0) {
        long v = va_arg(ap, long);
        printf("opt=%d LONG  value=%ld\n", opt, v);
    } else {
        void *v = va_arg(ap, void *);
        printf("opt=%d PTR   value=%p\n", opt, v);
    }
    va_end(ap);
    return 0;
}
