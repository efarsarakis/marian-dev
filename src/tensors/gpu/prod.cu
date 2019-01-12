
#include <cublas_v2.h>
#include <cusparse.h>

// clang-format off
#include "tensors/gpu/prod.h"
#include "tensors/gpu/backend.h"
#include "tensors/gpu/cuda_helpers.h"
// clang-format on

namespace marian {

namespace gpu {

static void setTensorMode(cublasHandle_t cublasHandle) {
  static int mode = 0;  // 1: use TC; -1: do not use TC; 0: not set yet
  if (mode == 0) { // multi-thread note: this is sort-of thread-safe, since multiple threads would determine the same value
    const char* var = getenv("ENABLE_CUBLAS_TENSOR_OP_MATH_FP32");
    if (!var)
      var = "1";
    switch(var[0]) {
    case '0': mode = -1; break;
    case '1': mode =  1; break;
    default: ABORT("Invalid ENABLE_CUBLAS_TENSOR_OP_MATH_FP32={}", var);
    }
    if (mode > 0) { // try whether it can be set   --@TODO: check whether this actually works
      CUBLAS_CHECK(cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH));
      cublasMath_t actual = CUBLAS_DEFAULT_MATH;
      cublasGetMathMode(cublasHandle, &actual);
      if (actual != CUBLAS_TENSOR_OP_MATH) {
        LOG(warn, "[gpu] TensorCores requested but not available");
        mode = -1;
      }
    }
    if (mode > 0)
      LOG(info, "[gpu] 16-bit TensorCores enabled for float32 matrix operations");
  }
  CUBLAS_CHECK(cublasSetMathMode(cublasHandle, mode > 0 ? CUBLAS_TENSOR_OP_MATH : CUBLAS_DEFAULT_MATH));
}

void Prod(marian::Tensor C,
          const marian::Tensor& A,
          const marian::Tensor& B,
          bool transA,
          bool transB,
          float beta,
          float scalar) {
  cudaSetDevice(C->getDeviceId().no);
  float alpha = scalar;

  size_t m = A->shape().elements() / A->shape().back();
  size_t k = A->shape().back();
  if(transA)
    std::swap(m, k);

  size_t l = B->shape().elements() / B->shape().back();
  size_t n = B->shape().back();
  if(transB)
    std::swap(l, n);

  size_t lda = A->shape().back();
  size_t ldb = B->shape().back();
  size_t ldc = B->shape().back();

  if(transB)
    ldc = B->shape().elements() / B->shape().back();

  cublasOperation_t opA = transA ? CUBLAS_OP_T : CUBLAS_OP_N;
  cublasOperation_t opB = transB ? CUBLAS_OP_T : CUBLAS_OP_N;

  auto cublasHandle = std::static_pointer_cast<gpu::Backend>(C->getBackend())
                          ->getCublasHandle();

#if CUDA_VERSION >= 9000
  setTensorMode(cublasHandle);
  //cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH);
#endif

  CUBLAS_CHECK(cublasSgemm(cublasHandle,
              opB,
              opA,
              n,
              m,
              k,
              &alpha,
              B->data(),
              ldb,
              A->data(),
              lda,
              &beta,
              C->data(),
              ldc));
#if CUDA_VERSION >= 9000
  cublasSetMathMode(cublasHandle, CUBLAS_DEFAULT_MATH);
#endif
}

__global__ void gAddBias(float* out,
                         const float* bias,
                         size_t length,
                         size_t cols) {
  for(int bid = 0; bid < length; bid += blockDim.x * gridDim.x) {
    int index = bid + blockDim.x * blockIdx.x + threadIdx.x;
    if(index < length) {
      size_t index2 = index % cols;
      out[index] += bias[index2];
    }
  }
}

#if 0 // @TODO: remove, then rename from .cu to .cpp
void AddBias(marian::Tensor C, const marian::Tensor bias) {
  cudaSetDevice(C->getDeviceId().no);

  int length = C->shape().elements();
  int cols = bias->shape().elements();

  int threads = std::min(MAX_THREADS, length);
  int blocks = std::min(MAX_BLOCKS, length / threads + (length % threads != 0));

  gAddBias<<<blocks, threads>>>(C->data(), bias->data(), length, cols); // @TODO: CUDA_CHECK

  CUDA_CHECK(cudaStreamSynchronize(0)); // @BUGBUG: Should not be here. Prod() also does not have this.
}

void ProdWithBias(marian::Tensor C,
                  const marian::Tensor& A,
                  const marian::Tensor& B,
                  const marian::Tensor& bias,
                  bool transA,
                  bool transB,
                  float beta,
                  float scalar) {
  marian::gpu::Prod(C, A, B, transA, transB, beta, scalar);
  marian::gpu::AddBias(C, bias);
}
#endif

void ProdBatched(marian::Tensor C,
                 Ptr<Allocator> allocator,
                 const marian::Tensor A,
                 const marian::Tensor B,
                 bool transA,
                 bool transB,
                 float beta,
                 float scalar) {
  cudaSetDevice(C->getDeviceId().no);
  float alpha = scalar;

  size_t batchA = A->shape().elements() / (A->shape()[-1] * A->shape()[-2]);
  size_t batchB = B->shape().elements() / (B->shape()[-1] * B->shape()[-2]);

  size_t m = A->shape()[-2];
  size_t k = A->shape()[-1];
  if(transA)
    std::swap(m, k);

  size_t l = B->shape()[-2];
  size_t n = B->shape()[-1];
  if(transB)
    std::swap(l, n);

  size_t lda = A->shape()[-1];
  size_t ldb = B->shape()[-1];
  size_t ldc = B->shape()[-1];

  if(transB)
    ldc = B->shape()[-2];

  cublasOperation_t opA = transA ? CUBLAS_OP_T : CUBLAS_OP_N;
  cublasOperation_t opB = transB ? CUBLAS_OP_T : CUBLAS_OP_N;

  auto cublasHandle = std::static_pointer_cast<gpu::Backend>(C->getBackend())
                          ->getCublasHandle();

  int strideA = batchA == 1 ? 0 : m * k;
  int strideB = batchB == 1 ? 0 : n * k;
  int strideC = n * m;
  int batchC = std::max(batchA, batchB);

  std::vector<const float*> aptr;
  std::vector<const float*> bptr;
  std::vector<float*> cptr;

  for(int i = 0; i < batchC; i++) {
    aptr.push_back(A->data() + (i % batchA) * strideA);
    bptr.push_back(B->data() + (i % batchB) * strideB);
    cptr.push_back(C->data() + i * strideC);
  }

  auto mp_aptr = allocator->alloc<const float*>(aptr.size());
  CudaCopy(
      aptr.data(), aptr.data() + aptr.size(), mp_aptr->data<const float*>());

  auto mp_bptr = allocator->alloc<const float*>(bptr.size());
  CudaCopy(
      bptr.data(), bptr.data() + bptr.size(), mp_bptr->data<const float*>());

  auto mp_cptr = allocator->alloc<float*>(cptr.size());
  CudaCopy(cptr.data(), cptr.data() + cptr.size(), mp_cptr->data<float*>());

#if CUDA_VERSION >= 9000
  setTensorMode(cublasHandle);
  //cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH);
#endif
  CUBLAS_CHECK(cublasSgemmBatched(cublasHandle,
                     opB,
                     opA,
                     n,
                     m,
                     k,
                     &alpha,
                     mp_bptr->data<const float*>(),
                     ldb,
                     mp_aptr->data<const float*>(),
                     lda,
                     &beta,
                     mp_cptr->data<float*>(),
                     ldc,
                     batchC));
#if CUDA_VERSION >= 9000
  cublasSetMathMode(cublasHandle, CUBLAS_DEFAULT_MATH);
#endif

  allocator->free(mp_aptr);
  allocator->free(mp_bptr);
  allocator->free(mp_cptr);
}

void CSRProd(marian::Tensor C,
             Ptr<Allocator> allocator,
             const marian::Tensor& A_values,
             const marian::Tensor& A_indices,
             const marian::Tensor& A_offsets,
             const marian::Tensor& B,
             bool transA,
             float beta) {
  cudaSetDevice(C->getDeviceId().no);
  auto cusparseHandle = std::static_pointer_cast<gpu::Backend>(C->getBackend())
                              ->getCusparseHandle();
  // dimensions
  const auto& shapeC = C->shape();
  const auto& shapeB = B->shape();
  auto rowsC = shapeC[0];
  auto colsC = shapeC.elements() / rowsC;
  auto rowsB = shapeB[0];
  auto colsB = shapeB.elements() / rowsB;
  auto rowsA = transA ? rowsB : rowsC;
  auto colsA = transA ? rowsC : rowsB;
  ABORT_IF((transA ? colsA : rowsA) != rowsC || (transA ? rowsA : colsA) != rowsB || colsB != colsC, "Inconsistent dimensions in CSR product");
  // sparse arrays
  auto numValues  = A_values->shape().elements();
  auto numOffsets = A_offsets->shape().elements() - 1; // -1 since last value is length
  LOG(info, "n={}, transA={}, rowsB={}, rowsC={}", numOffsets,transA, rowsB, rowsC);
  ABORT_IF(numOffsets != (transA ? rowsB : rowsC), "CSR offset array dimension mismatch: n={}, transA={}, rowsB={}, rowsC={}", numOffsets,transA, rowsB, rowsC);
  ABORT_IF(numOffsets != (transA ? rowsB : rowsC), "CSR offset array dimension mismatch");
  ABORT_IF(A_values->shape() != A_indices->shape(), "CSR values and indices must have the same size");
  float alpha = 1;
  // Marian uses row-major storage, but CUSPARSE/CUBLAS assume column-major.
  // Hence, we compute C = spA * B as C' = B' * spA'. where B' and C' are
  // column-major views on the data of B and C, and likewise, spA' is
  // the CSR matrix reinterpreted as a CSC matrix.
  if (transA) {
   //// transpose the second argument
   //ABORT("not implemented");
   //CUSPARSE_CHECK(cusparseSgemmi(cusparseHandle,
   //    /*m=*/ colsB, // #rows of A = #cols of row-major B
   //    /*n=*/ rowsC, // #cols of B and C = #rows of row-major C
   //    /*k=*/ rowsB, // #cols of A = #rows of row-major B
   //    /*nnz=*/ (int)numValues,
   //    &alpha,
   //    /*A=*/ B->data(),
   //    /*lda=*/ colsB, // stride
   //    /*cscValB=*/          A_values->data<float>(),  // second arg   --these get replaced
   //    /*cscRowPtrB=*/ (int*)A_offsets->data<IndexType>(),
   //    /*cscColIndB=*/ (int*)A_indices->data<IndexType>(),
   //    &beta,
   //    C->data(),
   //    /*ldc=*/ colsC)); // stride
  }
  else {
    CUSPARSE_CHECK(cusparseSgemmi(cusparseHandle,
        /*m=*/ colsB, // #rows of A = #cols of row-major B
        /*n=*/ rowsC, // #cols of B and C = #rows of row-major C
        /*k=*/ rowsB, // #cols of A = #rows of row-major B
        /*nnz=*/ (int)numValues,
        &alpha,
        /*A=*/ B->data(),
        /*lda=*/ colsB, // stride
        /*cscValB=*/          A_values->data<float>(),  // second arg
        /*cscRowPtrB=*/ (int*)A_offsets->data<IndexType>(),
        /*cscColIndB=*/ (int*)A_indices->data<IndexType>(),
        &beta,
        C->data(),
        /*ldc=*/ colsC)); // stride
  }
#if 0
  // Incorrect code that assumes col-major matrices. Reuse that later for dense x sparse.
  cusparseMatDescr_t descrA;
  CUSPARSE_CHECK(cusparseCreateMatDescr(&descrA));
  cusparseSetMatType     (descrA, CUSPARSE_MATRIX_TYPE_GENERAL);
  cusparseSetMatIndexBase(descrA, CUSPARSE_INDEX_BASE_ZERO);
  CUSPARSE_CHECK(cusparseScsrmm(cusparseHandle,
      transA ? CUSPARSE_OPERATION_TRANSPOSE : CUSPARSE_OPERATION_NON_TRANSPOSE,
      /*m=*/ rowsA, // #rows of sparse A
      /*n=*/ colsB, // #cols of dense B and C
      /*k=*/ colsA, // #cols of sparse A
      /*nnz=*/ (int)numValues,
      &alpha, descrA,
      /*csrValA=*/          A_values->data<float>(),
      /*csrRowPtrA=*/ (int*)A_offsets->data<IndexType>(),
      /*csrColIndA=*/ (int*)A_indices->data<IndexType>(),
      B->data(),
      /*ldb=*/ rowsB,
      &beta,
      C->data(),
      /*ldc=*/ rowsC));
  cusparseDestroyMatDescr(descrA);
#endif
}

}  // namespace gpu
}  // namespace marian
