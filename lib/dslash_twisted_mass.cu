#include <cstdlib>
#include <cstdio>
#include <string>
#include <iostream>

#include <color_spinor_field.h>
#include <clover_field.h>

// these control the Wilson-type actions
#ifdef GPU_WILSON_DIRAC
//#define DIRECT_ACCESS_LINK
//#define DIRECT_ACCESS_WILSON_SPINOR
//#define DIRECT_ACCESS_WILSON_ACCUM
//#define DIRECT_ACCESS_WILSON_INTER
//#define DIRECT_ACCESS_WILSON_PACK_SPINOR
//#define DIRECT_ACCESS_CLOVER
#endif // GPU_WILSON_DIRAC


#include <quda_internal.h>
#include <dslash_quda.h>
#include <sys/time.h>
#include <blas_quda.h>
#include <face_quda.h>

#include <inline_ptx.h>

namespace quda {

  namespace twisted {

#include <dslash_constants.h>
#include <dslash_textures.h>
#include <dslash_index.cuh>

    // Enable shared memory dslash for Fermi architecture
    //#define SHARED_WILSON_DSLASH
    //#define SHARED_8_BYTE_WORD_SIZE // 8-byte shared memory access

#include <tm_dslash_def.h>        // Twisted Mass kernels
#include <tm_ndeg_dslash_def.h>   // Non-degenerate twisted Mass

#ifndef DSLASH_SHARED_FLOATS_PER_THREAD
#define DSLASH_SHARED_FLOATS_PER_THREAD 0
#endif

#ifndef NDEGTM_SHARED_FLOATS_PER_THREAD
#define NDEGTM_SHARED_FLOATS_PER_THREAD 0
#endif

#include <dslash_quda.cuh>

  } // end namespace twisted
  
  // declare the dslash events
#include <dslash_events.cuh>

  using namespace twisted;

  template <typename sFloat, typename gFloat>
  class TwistedDslashCuda : public SharedDslashCuda {

  private:
    const gFloat *gauge0, *gauge1;
    const QudaTwistDslashType dslashType;
    const int dagger;
    double a, b, c, d;

  protected:
    unsigned int sharedBytesPerThread() const
    {
#if (__COMPUTE_CAPABILITY__ >= 200)
      if (dslashParam.kernel_type == INTERIOR_KERNEL) {
	int reg_size = (typeid(sFloat)==typeid(double2) ? sizeof(double) : sizeof(float));
	return ((in->TwistFlavor() == QUDA_TWIST_PLUS || in->TwistFlavor() == QUDA_TWIST_MINUS) ? DSLASH_SHARED_FLOATS_PER_THREAD * reg_size : NDEGTM_SHARED_FLOATS_PER_THREAD * reg_size);
      } else {
	return 0;
      }
#else
      int reg_size = (typeid(sFloat)==typeid(double2) ? sizeof(double) : sizeof(float));
      return ((in->TwistFlavor() == QUDA_TWIST_PLUS || in->TwistFlavor() == QUDA_TWIST_MINUS) ? DSLASH_SHARED_FLOATS_PER_THREAD * reg_size : NDEGTM_SHARED_FLOATS_PER_THREAD * reg_size);
#endif
    }

  public:
    TwistedDslashCuda(cudaColorSpinorField *out, const gFloat *gauge0, const gFloat *gauge1, 
		      const QudaReconstructType reconstruct, const cudaColorSpinorField *in,  const cudaColorSpinorField *x, 
		      const QudaTwistDslashType dslashType, const double kappa, const double mu, 
		      const double epsilon, const double k, const int dagger)
      : SharedDslashCuda(out, in, x, reconstruct), gauge0(gauge0), gauge1(gauge1), 
	dslashType(dslashType), dagger(dagger)
    { 
      bindSpinorTex<sFloat>(in, out, x); 
      a = kappa;
      b = mu;
      c = epsilon;
      d = k;
    }
    virtual ~TwistedDslashCuda() { unbindSpinorTex<sFloat>(in, out, x); }

    TuneKey tuneKey() const
    {
      TuneKey key = DslashCuda::tuneKey();
      switch(dslashType){
      case QUDA_DEG_TWIST_INV_DSLASH:
	strcat(key.aux,",TwistInvDslash");
	break;
      case QUDA_DEG_DSLASH_TWIST_INV:
	strcat(key.aux,",");
	break;
      case QUDA_DEG_DSLASH_TWIST_XPAY:
	strcat(key.aux,",DslashTwist");
	break;
      case QUDA_NONDEG_DSLASH:
	strcat(key.aux,",NdegDslash");
	break;
      }
      return key;
    }

    void apply(const cudaStream_t &stream)
    {

#ifdef SHARED_WILSON_DSLASH
      if (dslashParam.kernel_type == EXTERIOR_KERNEL_X) 
	errorQuda("Shared dslash does not yet support X-dimension partitioning");
#endif
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

      switch(dslashType){
      case QUDA_DEG_TWIST_INV_DSLASH:
	DSLASH(twistedMassTwistInvDslash, tp.grid, tp.block, tp.shared_bytes, stream, dslashParam,
	       (sFloat*)out->V(), (float*)out->Norm(), gauge0, gauge1, 
	       (sFloat*)in->V(), (float*)in->Norm(), a, b, (sFloat*)(x ? x->V() : 0), (float*)(x ? x->Norm() : 0));
	break;
      case QUDA_DEG_DSLASH_TWIST_INV:
	DSLASH(twistedMassDslash, tp.grid, tp.block, tp.shared_bytes, stream, dslashParam,
	       (sFloat*)out->V(), (float*)out->Norm(), gauge0, gauge1, 
	       (sFloat*)in->V(), (float*)in->Norm(), a, b, (sFloat*)(x ? x->V() : 0), (float*)(x ? x->Norm() : 0));
	break;
      case QUDA_DEG_DSLASH_TWIST_XPAY:
	DSLASH(twistedMassDslashTwist, tp.grid, tp.block, tp.shared_bytes, stream, dslashParam,
	       (sFloat*)out->V(), (float*)out->Norm(), gauge0, gauge1, 
	       (sFloat*)in->V(), (float*)in->Norm(), a, b, (sFloat*)x->V(), (float*)x->Norm());
	break;
      case QUDA_NONDEG_DSLASH:
	NDEG_TM_DSLASH(twistedNdegMassDslash, tp.grid, tp.block, tp.shared_bytes, stream, dslashParam,
		       (sFloat*)out->V(), (float*)out->Norm(), gauge0, gauge1, 
		       (sFloat*)in->V(), (float*)in->Norm(), a, b, c, d, (sFloat*)(x ? x->V() : 0), (float*)(x ? x->Norm() : 0));
	break;
      default: errorQuda("Invalid twisted mass dslash type");
      }
    }

    long long flops() const { return (x ? 1416ll : 1392ll) * dslashConstants.VolumeCB(); } // FIXME for multi-GPU
  };

#include <dslash_policy.cuh> 

  void twistedMassDslashCuda(cudaColorSpinorField *out, const cudaGaugeField &gauge, 
			     const cudaColorSpinorField *in, const int parity, const int dagger, 
			     const cudaColorSpinorField *x, const QudaTwistDslashType type, const double &kappa, const double &mu, 
			     const double &epsilon, const double &k,  const int *commOverride,
			     TimeProfile &profile, const QudaDslashPolicy &dslashPolicy)
  {
    inSpinor = (cudaColorSpinorField*)in; // EVIL
#ifdef GPU_TWISTED_MASS_DIRAC
    int Npad = (in->Ncolor()*in->Nspin()*2)/in->FieldOrder(); // SPINOR_HOP in old code

    int ghost_threads[4] = {0};
    int bulk_threads = ((in->TwistFlavor() == QUDA_TWIST_PLUS) || (in->TwistFlavor() == QUDA_TWIST_MINUS)) ? in->Volume() : in->Volume() / 2;

    for(int i=0;i<4;i++){
      dslashParam.ghostDim[i] = commDimPartitioned(i); // determines whether to use regular or ghost indexing at boundary
      dslashParam.ghostOffset[i] = Npad*(in->GhostOffset(i) + in->Stride());
      dslashParam.ghostNormOffset[i] = in->GhostNormOffset(i) + in->Stride();
      dslashParam.commDim[i] = (!commOverride[i]) ? 0 : commDimPartitioned(i); // switch off comms if override = 0
      ghost_threads[i] = ((in->TwistFlavor() == QUDA_TWIST_PLUS) || (in->TwistFlavor() == QUDA_TWIST_MINUS)) ? in->GhostFace()[i] : in->GhostFace()[i] / 2;
    }

#ifdef MULTI_GPU
    if(type == QUDA_DEG_TWIST_INV_DSLASH){
      setTwistPack(true);
      twist_a = kappa; 
      twist_b = mu;
    }
#endif

    void *gauge0, *gauge1;
    bindGaugeTex(gauge, parity, &gauge0, &gauge1);

    if (in->Precision() != gauge.Precision())
      errorQuda("Mixing gauge and spinor precision not supported");

    DslashCuda *dslash = 0;
    size_t regSize = sizeof(float);

    if (in->Precision() == QUDA_DOUBLE_PRECISION) {
#if (__COMPUTE_CAPABILITY__ >= 130)
      dslash = new TwistedDslashCuda<double2,double2>(out, (double2*)gauge0,(double2*)gauge1, gauge.Reconstruct(), in, x, type, kappa, mu, epsilon, k, dagger);
      regSize = sizeof(double);
#else
      errorQuda("Double precision not supported on this GPU");
#endif
    } else if (in->Precision() == QUDA_SINGLE_PRECISION) {
      dslash = new TwistedDslashCuda<float4,float4>(out, (float4*)gauge0,(float4*)gauge1, gauge.Reconstruct(), in, x, type, kappa, mu, epsilon, k, dagger);

    } else if (in->Precision() == QUDA_HALF_PRECISION) {
      dslash = new TwistedDslashCuda<short4,short4>(out, (short4*)gauge0,(short4*)gauge1, gauge.Reconstruct(), in, x, type, kappa, mu, epsilon, k, dagger);
    }

    dslashCuda(*dslash, regSize, parity, dagger, bulk_threads, ghost_threads, profile);

    delete dslash;
#ifdef MULTI_GPU
    if(type == QUDA_DEG_TWIST_INV_DSLASH){
      setTwistPack(false);
      twist_a = 0.0; 
      twist_b = 0.0;
    }
#endif

    unbindGaugeTex(gauge);

    checkCudaError();
#else
    errorQuda("Twisted mass dslash has not been built");
#endif
  }

}