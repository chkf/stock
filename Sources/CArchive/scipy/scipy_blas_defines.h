/* Standard LP64 Fortran BLAS/LAPACK ABI on Accelerate and Linux. */
#ifndef STOCK_BLAS_DEFINES_H
#define STOCK_BLAS_DEFINES_H
#include <stdint.h>
#include <string.h>
#define CBLAS_INT int32_t
#define BLAS_FUNC(name) name ## _
#endif
