#include "include/CArchive.h"
#include "scipy/slsqp.h"
#include <stdlib.h>

extern void dsyrk_(char *, char *, int *, int *, double *, double *, int *, double *, double *, int *);
void sr_gram_matrix(int n, int observations, double *centered, double *product) {
    double one = 1, zero = 0;
    dsyrk_("U", "T", &n, &observations, &one, centered, &observations, &zero, product, &n);
    for (int j=0; j<n; ++j)
        for (int i=0; i<j; ++i) product[i*n+j] = product[j*n+i];
}

/* scipy.optimize._minimize_slsqp, one equality constraint and box bounds.
   SLSQP and its NNLS subproblem are the SciPy 1.18.1 release sources. */
int sr_minimum_variance(int n, const double *c, double *w) {
    if (n < 3 || n > 28 || !c || !w) return -100;
    struct SLSQP_vars s = {.acc=1e-10, .tol=1e-9, .itermax=300, .m=1, .meq=1, .n=n};
    const size_t length = n*(n+1)/2 + 3*n - (1+5*n+7) + 9 + 8*n*n + 35*n + 1 + 28 + 2*n*(n+1);
    double *work = calloc(length, sizeof(double));
    if (!work) return -101;
    CBLAS_INT indices[59] = {0};
    double lower[28] = {0}, upper[28], gradient[28], normal[28], multipliers[59] = {0};
    double f = 0, residual = 0;
    for (int i=0; i<n; ++i) {
        w[i] = 1.0/n;
        upper[i] = 0.35;
        normal[i] = 1.0;
    }
    CBLAS_INT stride = 1, size = n;
    double one = 1, zero = 0;
    do {
        double product[28] = {0};
        BLAS_FUNC(dgemv)("N", &size, &size, &one, (double *)c, &size, w, &stride, &zero, product, &stride);
        if (s.mode >= 0) {
            f = BLAS_FUNC(ddot)(&size, product, &stride, w, &stride);
            /* numpy's pairwise sum for a contiguous float64 vector. */
            int i = 0;
            residual = -0.0;
            if (n >= 8) {
                double lanes[8];
                for (i=0; i<8; ++i) lanes[i] = w[i];
                for (; i+7<n; i+=8)
                    for (int j=0; j<8; ++j) lanes[j] += w[i+j];
                residual = ((lanes[0]+lanes[1])+(lanes[2]+lanes[3])) +
                           ((lanes[4]+lanes[5])+(lanes[6]+lanes[7]));
            }
            for (; i<n; ++i) residual += w[i];
            residual -= 1.0;
        }
        if (s.mode <= 0)
            for (int i=0; i<n; ++i) gradient[i] = 2.0 * product[i];
        __slsqp_body(&s, &f, gradient, normal, &residual, w, multipliers, lower, upper, work, indices);
    } while (s.mode == 1 || s.mode == -1);
    free(work);
    return (int)s.mode;
}
