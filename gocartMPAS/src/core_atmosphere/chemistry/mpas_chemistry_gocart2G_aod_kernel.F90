!=================================================================================================================
 module mpas_chemistry_gocart2G_aod_kernel
!=================================================================================================================
! Arithmetic of the AOD constraint: the ratio by which aerosol is scaled toward an observed aerosol optical
! depth (AOD), the layer that holds the tropopause, and the combination of two observation snapshots in time.
! The module depends only on the working real kind, so it is compiled and tested outside the model
! (scripts/test_aod_kernel.sh).
!
! Lineage: the ratio, tropospheric-ratio, below-tropopause, time-weight, and snapshot rules follow
! aod_nudging_kernel.F90 of NCAR/CERES-SARB-CAM7 (the CESM3-CAM7 AOD nudging by D. Fillmore), including its
! tropospheric option. tropopause_layer and partition_optical_depth are new here: CAM diagnoses a tropopause
! level itself, this model is given a tropopause pressure.
!
! Conventions: layers are numbered from the model top down. Layer k lies between the edge pressures ple(k),
! its top, and ple(k+1), its bottom.

 use mpas_kind_types,only: RKIND

 implicit none
 private
 public:: aod_ratio,                &
          aod_tropospheric_ratio,   &
          below_tropopause,         &
          tropopause_layer,         &
          partition_optical_depth,  &
          interp_weight,            &
          combine_snapshots

!--- value that marks "no valid observation" in the observation files. Any negative value is treated as fill.
 real(kind=RKIND),parameter,public:: AOD_FILL = -999._RKIND


 contains


!=================================================================================================================
 elemental function aod_ratio(target_aod,model_aod,valid,eps,rmin,rmax) result(ratio)
!=================================================================================================================
! Observed over modelled AOD, limited to [rmin,rmax]. Returns 1 (no change) where there is no valid
! observation or where the modelled AOD is below eps, which would make the ratio meaningless.

 real(kind=RKIND),intent(in):: target_aod  ! observed AOD (AOD_FILL where there is none)
 real(kind=RKIND),intent(in):: model_aod   ! modelled AOD that the scaling can change
 logical,intent(in):: valid                ! .true. where the observation may be used
 real(kind=RKIND),intent(in):: eps         ! smallest modelled AOD that is scaled
 real(kind=RKIND),intent(in):: rmin,rmax   ! limits of the ratio
 real(kind=RKIND):: ratio

 ratio = 1._RKIND
 if(.not. valid)             return
 if(target_aod < 0._RKIND)   return
 if(model_aod < eps)         return
 ratio = target_aod/model_aod
 if(ratio < rmin) ratio = rmin
 if(ratio > rmax) ratio = rmax

 end function aod_ratio

!=================================================================================================================
 elemental function aod_tropospheric_ratio(target_aod,total_aod,eligible_aod,valid,eps,rmin,rmax) result(ratio)
!=================================================================================================================
! Ratio for the layers that may be scaled when the rest of the column is held fixed. The fixed part of the
! modelled AOD is subtracted from the observation, and the eligible part has to make up the remainder. An
! observation below the fixed part cannot be matched; it gives the lower limit rmin.

 real(kind=RKIND),intent(in):: target_aod    ! observed column AOD
 real(kind=RKIND),intent(in):: total_aod     ! modelled column AOD
 real(kind=RKIND),intent(in):: eligible_aod  ! modelled AOD of the layers that may be scaled
 logical,intent(in):: valid
 real(kind=RKIND),intent(in):: eps,rmin,rmax
 real(kind=RKIND):: ratio

 real(kind=RKIND):: fixed_aod

 fixed_aod = max(0._RKIND,total_aod-eligible_aod)
 ratio = aod_ratio(max(0._RKIND,target_aod-fixed_aod),eligible_aod, &
                   valid .and. target_aod >= 0._RKIND,eps,rmin,rmax)

 end function aod_tropospheric_ratio

!=================================================================================================================
 elemental function below_tropopause(k,k_tropopause,nlayers) result(below)
!=================================================================================================================
! .true. for layers strictly below the layer that holds the tropopause. That layer and all above it are
! protected. Without a valid tropopause layer no layer is below it: a failed diagnosis never permits scaling.

 integer,intent(in):: k             ! layer, counted from the model top
 integer,intent(in):: k_tropopause  ! layer that holds the tropopause; 0 if there is none
 integer,intent(in):: nlayers
 logical:: below

 below = k_tropopause >= 1 .and. k_tropopause <= nlayers .and. k > k_tropopause

 end function below_tropopause

!=================================================================================================================
 pure function tropopause_layer(ple,ptrop) result(k_tropopause)
!=================================================================================================================
! Layer that holds the pressure ptrop: the k with ple(k) < ptrop <= ple(k+1). Returns 0 where ptrop is not a
! usable pressure (not positive, at or above the model top, or below the surface).

 real(kind=RKIND),intent(in):: ple(:)  ! edge pressures from the model top down, size nlayers+1 [Pa]
 real(kind=RKIND),intent(in):: ptrop   ! tropopause pressure [Pa]
 integer:: k_tropopause

 integer:: k,nlayers

 k_tropopause = 0
 nlayers = size(ple)-1
 if(nlayers < 1)               return
 if(.not. (ptrop > 0._RKIND))  return
 if(ptrop <= ple(1))           return
 if(ptrop > ple(nlayers+1))    return
 do k = 1,nlayers
    if(ptrop <= ple(k+1)) then
       k_tropopause = k
       return
    endif
 enddo

 end function tropopause_layer

!=================================================================================================================
 pure subroutine partition_optical_depth(tau,k_tropopause,tropo_only,total_aod,eligible_aod)
!=================================================================================================================
! Column AOD and the part of it in the layers that may be scaled. With tropo_only those are the layers below
! the tropopause layer; without it, every layer.

 real(kind=RKIND),intent(in):: tau(:)   ! layer optical depth from the model top down
 integer,intent(in):: k_tropopause
 logical,intent(in):: tropo_only
 real(kind=RKIND),intent(out):: total_aod,eligible_aod

 integer:: k,nlayers

 nlayers = size(tau)
 total_aod    = 0._RKIND
 eligible_aod = 0._RKIND
 do k = 1,nlayers
    total_aod = total_aod + tau(k)
    if(tropo_only) then
       if(below_tropopause(k,k_tropopause,nlayers)) eligible_aod = eligible_aod + tau(k)
    else
       eligible_aod = eligible_aod + tau(k)
    endif
 enddo

 end subroutine partition_optical_depth

!=================================================================================================================
 elemental function interp_weight(t_model,t_before,t_after) result(w)
!=================================================================================================================
! Weight of the later snapshot, so that the target is (1-w)*before + w*after. Times are in one unit, for
! example seconds. Snapshots that do not bracket a positive interval give w = 0.

 real(kind=RKIND),intent(in):: t_model,t_before,t_after
 real(kind=RKIND):: w

 real(kind=RKIND):: span

 span = t_after-t_before
 if(span <= 0._RKIND) then
    w = 0._RKIND
    return
 endif
 w = (t_model-t_before)/span
 if(w < 0._RKIND) w = 0._RKIND
 if(w > 1._RKIND) w = 1._RKIND

 end function interp_weight

!=================================================================================================================
 elemental subroutine combine_snapshots(before,after,before_valid,after_valid,w,target_aod,valid)
!=================================================================================================================
! One target from the two snapshots around the model time: both valid, interpolate; one valid, use it;
! neither, no observation.

 real(kind=RKIND),intent(in):: before,after
 logical,intent(in):: before_valid,after_valid
 real(kind=RKIND),intent(in):: w
 real(kind=RKIND),intent(out):: target_aod
 logical,intent(out):: valid

 if(before_valid .and. after_valid) then
    target_aod = (1._RKIND-w)*before + w*after
    valid = .true.
 elseif(before_valid) then
    target_aod = before
    valid = .true.
 elseif(after_valid) then
    target_aod = after
    valid = .true.
 else
    target_aod = AOD_FILL
    valid = .false.
 endif

 end subroutine combine_snapshots

!=================================================================================================================
 end module mpas_chemistry_gocart2G_aod_kernel
!=================================================================================================================
