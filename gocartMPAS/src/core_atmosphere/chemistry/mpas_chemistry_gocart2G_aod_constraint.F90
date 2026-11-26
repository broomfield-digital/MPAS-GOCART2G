!=================================================================================================================
 module mpas_chemistry_gocart2G_aod_constraint
!=================================================================================================================
! AOD constraint. Where there is a valid observation of aerosol optical depth (AOD) at 550 nm, the aerosol
! mass is multiplied by one factor per column so that the modelled column AOD matches the observation. With
! config_gocart2G_aod_tropo_only, only the layers below the layer that holds the tropopause are scaled; the
! tropopause layer and everything above keep their mass, and their optical depth is subtracted from the
! observation first. It is a replacement of the aerosol state, with no relaxation time.
!
! The method follows the AOD nudging of CESM3-CAM7 in NCAR/CERES-SARB-CAM7 (D. Fillmore), including its
! tropospheric option; see mpas_chemistry_gocart2G_aod_kernel.F90 for the arithmetic. Three things differ
! here because GOCART-2G is a bulk mass scheme:
!   - there is no particle number or cached aerosol water to keep consistent with the mass;
!   - extinction is linear in mass at fixed relative humidity, so the column AOD after the update is the
!     fixed part plus the factor times the scaled part, without a second pass through the optics;
!   - the layer optical depth is recovered from the extinction coefficient that the diagnostics have just
!     computed, tau = extcoef*delp/(grav*airdens), which is how that coefficient was formed.
!
! Every particulate tracer that the aerosol processes use is scaled: the twenty that enter the 550 nm
! extinction (dust, sea salt, sulfate SO4, nitrate NO3an1-3, and black, brown, and organic carbon), and
! ammonium (NH4a) and MSA, which are part of the same particles though the optics do not count them
! separately. Gases (SO2, DMS, NH3), the SOA precursors, and the SO2v and SO4v tracers, which no process
! uses, are not scaled.
!
! Ammonium has to be scaled with sulfate and nitrate. The nitrate thermodynamics depends on the ratio of
! ammonium to sulfate; scaling sulfate and nitrate alone changes that ratio, and in a test the fine nitrate
! of strongly scaled columns then evaporated within one time step. Scaled together, the ratios and the
! gas-phase equilibrium are unchanged.
!
! Layers are numbered from the model top down in the GOCART-2G interface arrays used here.

 use mpas_log
 use mpas_kind_types
 use mpas_derived_types
 use mpas_dmpar,only: mpas_dmpar_sum_int_array,mpas_dmpar_sum_real_array
 use mpas_pool_routines,only: mpas_pool_get_config,mpas_pool_get_array

 use mpas_chemistry_gocart2G_aod_kernel
 use mpas_chemistry_gocart2G_aod_obs,only: aod_obs_weight,aod_obs_before_usable,aod_obs_after_usable
 use mpas_chemistry_gocart2G_vars,only: mpas_gocart2G,GOCART2G,DU2G,SS2G

 implicit none
 private
 public:: gocart2G_aod_constraint, &
          gocart2G_aod_report

!--- gravity as used by the GOCART-2G components when they form the extinction coefficient:
 real(kind=RKIND),parameter:: grav = 9.80616_RKIND

!--- index of the 550 nm wavelength in the profile optical properties (the only one in this configuration):
 integer,parameter:: iw550 = 1

!--- tallies over the cells of this task since the last report:
 integer,parameter:: n_count = 7
 integer,parameter:: ic_cells = 1, ic_observed = 2, ic_applied = 3, ic_low = 4, ic_high = 5, &
                     ic_below = 6, ic_notrop = 7
 integer,parameter:: n_sum = 3
 integer,parameter:: is_observed = 1, is_first_guess = 2, is_analyzed = 3
 integer:: tally(n_count)       = 0
 real(kind=RKIND):: total(n_sum) = 0._RKIND


 contains


!=================================================================================================================
 subroutine gocart2G_aod_constraint(configs,aod_constraint,do_CA2Gbc,do_CA2Gbr,do_CA2Goc, &
                                    do_DU2G,do_NI2G,do_SS2G,do_SU2G)
!=================================================================================================================
! Called once per block at the end of the chemistry, after the 550 nm diagnostics and before the tracers are
! written back to the model state.

!--- input arguments:
 type(mpas_pool_type),intent(in):: configs
 type(mpas_pool_type),intent(in):: aod_constraint
 logical,intent(in):: do_CA2Gbc,do_CA2Gbr,do_CA2Goc,do_DU2G,do_NI2G,do_SS2G,do_SU2G

!--- local variables and pointers:
 logical,pointer:: tropo_only
 real(kind=RKIND),pointer:: ratio_min,ratio_max,eps

 real(kind=RKIND),dimension(:),pointer:: obs_before,obs_after
 real(kind=RKIND),dimension(:),pointer:: observed_aod,first_guess_aod,analyzed_aod
 real(kind=RKIND),dimension(:),pointer:: tropospheric_aod,stratospheric_aod
 real(kind=RKIND),dimension(:),pointer:: scale_factor,update_applied,clamped_low,clamped_high
 real(kind=RKIND),dimension(:),pointer:: below_stratosphere,tropopause_pressure

 real(kind=RKIND),dimension(:),allocatable:: tau,ple
 real(kind=RKIND):: ptrop,total_aod,eligible_aod,fixed_aod,target_aod,ratio,analyzed

 integer:: i,j,k,its,ite,kts,kte,nlayers,k_tropopause
 logical:: valid,applied

!-----------------------------------------------------------------------------------------------------------------

 call mpas_pool_get_config(configs,'config_gocart2G_aod_tropo_only',tropo_only)
 call mpas_pool_get_config(configs,'config_gocart2G_aod_ratio_min' ,ratio_min )
 call mpas_pool_get_config(configs,'config_gocart2G_aod_ratio_max' ,ratio_max )
 call mpas_pool_get_config(configs,'config_gocart2G_aod_eps'       ,eps       )

 call mpas_pool_get_array(aod_constraint,'aod_obs_before'         ,obs_before         )
 call mpas_pool_get_array(aod_constraint,'aod_obs_after'          ,obs_after          )
 call mpas_pool_get_array(aod_constraint,'observed_aod'           ,observed_aod       )
 call mpas_pool_get_array(aod_constraint,'first_guess_aod'        ,first_guess_aod    )
 call mpas_pool_get_array(aod_constraint,'analyzed_aod'           ,analyzed_aod       )
 call mpas_pool_get_array(aod_constraint,'tropospheric_aod'       ,tropospheric_aod   )
 call mpas_pool_get_array(aod_constraint,'stratospheric_aod'      ,stratospheric_aod  )
 call mpas_pool_get_array(aod_constraint,'aod_scale_factor'       ,scale_factor       )
 call mpas_pool_get_array(aod_constraint,'aod_update_applied'     ,update_applied     )
 call mpas_pool_get_array(aod_constraint,'aod_clamped_low'        ,clamped_low        )
 call mpas_pool_get_array(aod_constraint,'aod_clamped_high'       ,clamped_high       )
 call mpas_pool_get_array(aod_constraint,'aod_below_stratosphere' ,below_stratosphere )
 call mpas_pool_get_array(aod_constraint,'aod_tropopause_pressure',tropopause_pressure)

 if(.not. associated(GOCART2G%totextcoef)) then
    call mpas_log_write('AOD constraint: the 550 nm extinction coefficient is not available.', &
                        messageType=MPAS_LOG_CRIT)
 endif

 its = mpas_gocart2G%its ; ite = mpas_gocart2G%ite
 kts = mpas_gocart2G%kts ; kte = mpas_gocart2G%kte
 j   = mpas_gocart2G%jts
 nlayers = kte-kts+1
 allocate(tau(nlayers),ple(nlayers+1))

 do i = its,ite

    !--- layer optical depth at 550 nm of the first guess, and the layer that holds the tropopause:
    do k = kts,kte
       tau(k-kts+1) = GOCART2G%totextcoef(i,j,k,iw550)*mpas_gocart2G%delp(i,j,k) &
                    / (grav*mpas_gocart2G%airdens(i,j,k))
    enddo
    ple(1:nlayers+1) = mpas_gocart2G%ple(i,j,kts:kte+1)

    k_tropopause = 0
    ptrop = 0._RKIND
    if(tropo_only) then
       ptrop = mpas_gocart2G%backg_ptrop(i,j)
       k_tropopause = tropopause_layer(ple,ptrop)
       if(k_tropopause == 0) ptrop = 0._RKIND
    endif
    call partition_optical_depth(tau,k_tropopause,tropo_only,total_aod,eligible_aod)
    fixed_aod = max(0._RKIND,total_aod-eligible_aod)

    !--- observation at the end of this time step:
    call combine_snapshots(obs_before(i),obs_after(i),                    &
                           aod_obs_before_usable .and. obs_before(i) >= 0._RKIND, &
                           aod_obs_after_usable  .and. obs_after(i)  >= 0._RKIND, &
                           aod_obs_weight,target_aod,valid)

    ratio   = aod_tropospheric_ratio(target_aod,total_aod,eligible_aod,valid,eps,ratio_min,ratio_max)
    applied = valid .and. eligible_aod >= eps

    !--- scale the aerosol in the eligible layers:
    if(applied .and. ratio /= 1._RKIND) then
       do k = kts,kte
          if(tropo_only) then
             if(.not. below_tropopause(k-kts+1,k_tropopause,nlayers)) cycle
          endif
          call scale_layer(i,j,k,ratio)
       enddo
    endif

    !--- diagnostics. Extinction is linear in mass, so the analyzed column is known without new optics:
    analyzed = total_aod
    if(applied) analyzed = fixed_aod + ratio*eligible_aod

    observed_aod(i)        = target_aod
    first_guess_aod(i)     = total_aod
    analyzed_aod(i)        = analyzed
    tropospheric_aod(i)    = eligible_aod
    stratospheric_aod(i)   = fixed_aod
    scale_factor(i)        = ratio
    tropopause_pressure(i) = ptrop
    update_applied(i)      = merge(1._RKIND,0._RKIND,applied)
    clamped_low(i)         = merge(1._RKIND,0._RKIND,applied .and. ratio <= ratio_min)
    clamped_high(i)        = merge(1._RKIND,0._RKIND,applied .and. ratio >= ratio_max)
    below_stratosphere(i)  = merge(1._RKIND,0._RKIND,applied .and. target_aod < fixed_aod)

    tally(ic_cells) = tally(ic_cells) + 1
    if(valid) tally(ic_observed) = tally(ic_observed) + 1
    if(tropo_only .and. k_tropopause == 0) tally(ic_notrop) = tally(ic_notrop) + 1
    if(applied) then
       tally(ic_applied) = tally(ic_applied) + 1
       if(ratio <= ratio_min)     tally(ic_low)   = tally(ic_low)   + 1
       if(ratio >= ratio_max)     tally(ic_high)  = tally(ic_high)  + 1
       if(target_aod < fixed_aod) tally(ic_below) = tally(ic_below) + 1
       total(is_observed)    = total(is_observed)    + target_aod
       total(is_first_guess) = total(is_first_guess) + total_aod
       total(is_analyzed)    = total(is_analyzed)    + analyzed
    endif

 enddo

 deallocate(tau,ple)


 contains


 !================================================================================================================
  subroutine scale_layer(i,j,k,ratio)
 !================================================================================================================
 ! Multiply every particulate tracer by ratio in one layer of one column. The carbon, nitrate, and sulfate
 ! components point at the interface arrays. Dust and sea salt hold their own copies, which the feedback to
 ! physics and the radiation band optics read, so both are scaled.

  integer,intent(in):: i,j,k
  real(kind=RKIND),intent(in):: ratio

  if(do_DU2G) then
     mpas_gocart2G%qdust1(i,j,k) = ratio*mpas_gocart2G%qdust1(i,j,k)
     mpas_gocart2G%qdust2(i,j,k) = ratio*mpas_gocart2G%qdust2(i,j,k)
     mpas_gocart2G%qdust3(i,j,k) = ratio*mpas_gocart2G%qdust3(i,j,k)
     mpas_gocart2G%qdust4(i,j,k) = ratio*mpas_gocart2G%qdust4(i,j,k)
     mpas_gocart2G%qdust5(i,j,k) = ratio*mpas_gocart2G%qdust5(i,j,k)
     DU2G%du(i,j,k,:) = ratio*DU2G%du(i,j,k,:)
  endif
  if(do_SS2G) then
     mpas_gocart2G%qseas1(i,j,k) = ratio*mpas_gocart2G%qseas1(i,j,k)
     mpas_gocart2G%qseas2(i,j,k) = ratio*mpas_gocart2G%qseas2(i,j,k)
     mpas_gocart2G%qseas3(i,j,k) = ratio*mpas_gocart2G%qseas3(i,j,k)
     mpas_gocart2G%qseas4(i,j,k) = ratio*mpas_gocart2G%qseas4(i,j,k)
     mpas_gocart2G%qseas5(i,j,k) = ratio*mpas_gocart2G%qseas5(i,j,k)
     SS2G%ss(i,j,k,:) = ratio*SS2G%ss(i,j,k,:)
  endif
  if(do_SU2G) then
     mpas_gocart2G%qso4(i,j,k) = ratio*mpas_gocart2G%qso4(i,j,k)
     mpas_gocart2G%qmsa(i,j,k) = ratio*mpas_gocart2G%qmsa(i,j,k)
  endif
  if(do_NI2G) then
     mpas_gocart2G%qni1(i,j,k)  = ratio*mpas_gocart2G%qni1(i,j,k)
     mpas_gocart2G%qni2(i,j,k)  = ratio*mpas_gocart2G%qni2(i,j,k)
     mpas_gocart2G%qni3(i,j,k)  = ratio*mpas_gocart2G%qni3(i,j,k)
     mpas_gocart2G%qnh4a(i,j,k) = ratio*mpas_gocart2G%qnh4a(i,j,k)
  endif
  if(do_CA2Gbc) then
     mpas_gocart2G%qbcphobic(i,j,k) = ratio*mpas_gocart2G%qbcphobic(i,j,k)
     mpas_gocart2G%qbcphilic(i,j,k) = ratio*mpas_gocart2G%qbcphilic(i,j,k)
  endif
  if(do_CA2Gbr) then
     mpas_gocart2G%qbrphobic(i,j,k) = ratio*mpas_gocart2G%qbrphobic(i,j,k)
     mpas_gocart2G%qbrphilic(i,j,k) = ratio*mpas_gocart2G%qbrphilic(i,j,k)
  endif
  if(do_CA2Goc) then
     mpas_gocart2G%qocphobic(i,j,k) = ratio*mpas_gocart2G%qocphobic(i,j,k)
     mpas_gocart2G%qocphilic(i,j,k) = ratio*mpas_gocart2G%qocphilic(i,j,k)
  endif

  end subroutine scale_layer

 end subroutine gocart2G_aod_constraint

!=================================================================================================================
 subroutine gocart2G_aod_report(dminfo)
!=================================================================================================================
! Write one line to the log for the application just made, summed over all tasks, and reset the tallies.

!--- input arguments:
 type(dm_info),intent(in):: dminfo

!--- local variables:
 integer:: global_tally(n_count)
 real(kind=RKIND):: global_total(n_sum)
 real(kind=RKIND):: cells,applied

!-----------------------------------------------------------------------------------------------------------------

 call mpas_dmpar_sum_int_array(dminfo,n_count,tally,global_tally)
 call mpas_dmpar_sum_real_array(dminfo,n_sum,total,global_total)

 cells   = real(max(1,global_tally(ic_cells)),kind=RKIND)
 applied = real(max(1,global_tally(ic_applied)),kind=RKIND)

 call mpas_log_write('AOD constraint: cells = $i, observed = $i, updated = $i, at lower limit = $i, '// &
                     'at upper limit = $i, observation below fixed AOD = $i, without a tropopause layer = $i', &
                     intArgs=global_tally)
 call mpas_log_write('AOD constraint: fraction of cells updated = $r; means over updated cells: '// &
                     'observed = $r, first guess = $r, analyzed = $r',                             &
                     realArgs=(/real(global_tally(ic_applied),kind=RKIND)/cells, &
                                global_total(is_observed)/applied,               &
                                global_total(is_first_guess)/applied,            &
                                global_total(is_analyzed)/applied/))

 tally(:) = 0
 total(:) = 0._RKIND

 end subroutine gocart2G_aod_report

!=================================================================================================================
 end module mpas_chemistry_gocart2G_aod_constraint
!=================================================================================================================
