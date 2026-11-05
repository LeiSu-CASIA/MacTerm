#include <netdb.h>
#include <unistd.h>
// Only injected into our own test helper, never installed in the application.
static int delayed_getaddrinfo(const char *host,const char *service,const struct addrinfo *hints,struct addrinfo **result){(void)host;(void)service;(void)hints;usleep(5000000);*result=0;return EAI_AGAIN;}
__attribute__((used,section("__DATA,__interpose"))) static const struct {const void *replacement,*original;} replacements[]={{(const void*)delayed_getaddrinfo,(const void*)getaddrinfo}};
