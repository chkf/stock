#include "include/CWorkspaceJS.h"
#include "vendor/quickjs.h"
#include <CArchive.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
static int interrupted(JSRuntime *rt, void *opaque) {
    (void)rt;
    return monotonic_seconds() > *(double *)opaque;
}
static int bounded_dimension(JSContext *ctx, JSValueConst value, int minimum, int maximum, int32_t *result) {
    double number;
    if (!JS_IsNumber(value) || JS_ToFloat64(ctx,&number,value) || !isfinite(number) || floor(number)!=number || number<minimum || number>maximum) return 0;
    *result=(int32_t)number;
    return 1;
}
static int sized(JSContext *ctx, JSValueConst array, int expected) {
    JSValue count=JS_GetPropertyStr(ctx,array,"length");
    double length;
    int valid=JS_IsNumber(count) && !JS_ToFloat64(ctx,&length,count) && length==expected;
    JS_FreeValue(ctx,count);
    return valid;
}
static JSValue min_variance(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    int32_t n;
    if (argc != 2 || !bounded_dimension(ctx,argv[0],3,28,&n))
        return JS_ThrowTypeError(ctx, "minimumVariance expects 3..28 assets");
    if (!sized(ctx,argv[1],n*n)) return JS_ThrowTypeError(ctx,"invalid covariance dimensions");
    double c[28*28], weights[28];
    for (uint32_t i = 0; i < (uint32_t)(n*n); ++i) {
        JSValue item = JS_GetPropertyUint32(ctx, argv[1], i);
        int fail = !JS_IsNumber(item) || JS_ToFloat64(ctx, &c[i], item);
        JS_FreeValue(ctx, item);
        if (fail || !isfinite(c[i])) return JS_ThrowTypeError(ctx, "invalid covariance matrix");
    }
    int status = sr_minimum_variance(n, c, weights);
    if (status) return JS_ThrowInternalError(ctx, "SLSQP error %d", status);
    for (int32_t index=0;index<n;++index) if (!isfinite(weights[index])) return JS_ThrowInternalError(ctx,"nonfinite SLSQP solution");
    JSValue array = JS_NewArray(ctx);
    for (uint32_t i=0; i<(uint32_t)n; ++i) JS_SetPropertyUint32(ctx, array, i, JS_NewFloat64(ctx, weights[i]));
    return array;
}
void sws_free(char *text) { free(text); }
static JSValue gram(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    int32_t n, k;
    if (argc != 3 || !bounded_dimension(ctx,argv[0],1,28,&n) || !bounded_dimension(ctx,argv[1],1,6000,&k) || !sized(ctx,argv[2],n*k))
        return JS_ThrowTypeError(ctx,"gramMatrix expects 1..28 assets and 1..6000 observations");
    double *x = calloc((size_t)n*k,sizeof(double));
    if (!x) return JS_ThrowOutOfMemory(ctx);
    for (uint32_t i=0; i<(uint32_t)(n*k); ++i) {
        JSValue v = JS_GetPropertyUint32(ctx,argv[2],i);
        int invalid = !JS_IsNumber(v) || JS_ToFloat64(ctx,&x[i],v);
        JS_FreeValue(ctx,v);
        if (invalid || !isfinite(x[i])) { free(x); return JS_ThrowTypeError(ctx,"invalid observation"); }
    }
    double out[28*28];
    sr_gram_matrix(n,k,x,out);
    free(x);
    for (int index=0;index<n*n;++index) if (!isfinite(out[index])) return JS_ThrowInternalError(ctx,"nonfinite Gram matrix");
    JSValue a=JS_NewArray(ctx);
    for (uint32_t i=0; i<(uint32_t)(n*n); ++i) JS_SetPropertyUint32(ctx,a,i,JS_NewFloat64(ctx,out[i]));
    return a;
}
int sws_run(const char *program, const char *source_name, const char *input, int check_only, char **output) {
    *output = NULL;
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return -1;
    JS_SetMemoryLimit(rt, 48*1024*1024);
    JS_SetMaxStackSize(rt, 384*1024);
    double deadline = monotonic_seconds() + 1.5;
    JS_SetInterruptHandler(rt, interrupted, &deadline);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return -1; }
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "minimumVariance", JS_NewCFunction(ctx, min_variance, "minimumVariance", 2));
    JS_SetPropertyStr(ctx, global, "gramMatrix", JS_NewCFunction(ctx, gram, "gramMatrix", 3));
    JSValue value = JS_Eval(ctx, program, strlen(program), source_name, JS_EVAL_TYPE_GLOBAL);
    int ok = !JS_IsException(value);
    JS_FreeValue(ctx, value);
    JSValue fn = JS_GetPropertyStr(ctx, global, "run");
    if (ok && !JS_IsFunction(ctx, fn)) { JS_ThrowTypeError(ctx, "missing function run(input)"); ok = 0; }
    if (ok && !check_only) {
        JSValue arg = JS_ParseJSON(ctx, input, strlen(input), "input.json");
        value = JS_IsException(arg) ? JS_EXCEPTION : JS_Call(ctx, fn, JS_UNDEFINED, 1, &arg);
        JS_FreeValue(ctx, arg);
        JSValue encoded = JS_IsException(value) ? JS_EXCEPTION : JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
        ok = !JS_IsException(encoded) && !JS_IsUndefined(encoded);
        if (ok) {
            size_t size = 0;
            const char *text = JS_ToCStringLen(ctx, &size, encoded);
            if (text && size <= 4*1024*1024) *output = strdup(text);
            else { JS_ThrowRangeError(ctx, "result exceeds size limit"); ok = 0; }
            if (text) JS_FreeCString(ctx, text);
        }
        JS_FreeValue(ctx, encoded); JS_FreeValue(ctx, value);
    }
    if (!ok) {
        JSValue error = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, error);
        if (text) { *output = strdup(text); JS_FreeCString(ctx, text); }
        JS_FreeValue(ctx, error);
    }
    JS_FreeValue(ctx, fn); JS_FreeValue(ctx, global); JS_FreeContext(ctx); JS_FreeRuntime(rt);
    return ok ? 0 : -1;
}
