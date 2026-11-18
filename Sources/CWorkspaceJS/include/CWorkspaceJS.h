#ifndef STOCK_WORKSPACE_JS_H
#define STOCK_WORKSPACE_JS_H
#include <stddef.h>
// Caller owns the returned UTF-8 string (including the diagnostic on failure).
int sws_run(const char *program, const char *source_name, const char *input, int check_only, char **output);
void sws_free(char *text);
#endif
