/* 模拟调用方：覆盖 LONG / 指针 / OFF_T 三类选项，以及要被改写的低速保护两项 */
typedef int CURLoption;
int curl_easy_setopt(void *, CURLoption, ...);

int main(void)
{
    curl_easy_setopt(0, 13, 300L);                     /* CURLOPT_TIMEOUT (LONG) */
    curl_easy_setopt(0, 10002, "http://x");            /* CURLOPT_URL (PTR) */
    curl_easy_setopt(0, 30115, (long long)7213216146); /* CURLOPT_INFILESIZE_LARGE (OFF_T) */
    curl_easy_setopt(0, 19, 1L);                       /* LOW_SPEED_LIMIT ← 应被改成 0 */
    curl_easy_setopt(0, 20, 300L);                     /* LOW_SPEED_TIME  ← 应被改成 0 */
    return 0;
}
