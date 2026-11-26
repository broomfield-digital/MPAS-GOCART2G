!=================================================================================================================
 program test_aod_kernel
!=================================================================================================================
! Unit tests of the AOD-constraint arithmetic. Built and run by scripts/test_aod_kernel.sh; exits with a
! non-zero status if any check fails.

 use mpas_kind_types,only: RKIND
 use mpas_chemistry_gocart2G_aod_kernel

 implicit none

 real(kind=RKIND),parameter:: eps = 0.01_RKIND, rmin = 0.1_RKIND, rmax = 10._RKIND
 real(kind=RKIND),parameter:: tol = 1.e-6_RKIND
 integer:: nfail = 0, ncheck = 0

 call test_ratio()
 call test_tropospheric_ratio()
 call test_layers()
 call test_partition()
 call test_time()

 write(*,'(a,i0,a,i0,a)') 'test_aod_kernel: ',ncheck-nfail,' of ',ncheck,' checks passed'
 if(nfail > 0) stop 1


 contains


 subroutine check(ok,what)
 logical,intent(in):: ok
 character(len=*),intent(in):: what
 ncheck = ncheck + 1
 if(.not. ok) then
    nfail = nfail + 1
    write(*,'(2a)') 'FAIL: ',what
 endif
 end subroutine check

 logical function near(a,b)
 real(kind=RKIND),intent(in):: a,b
 near = abs(a-b) <= tol*max(1._RKIND,abs(b))
 end function near

 subroutine test_ratio()
 real(kind=RKIND):: r(3)
 call check(near(aod_ratio(0.3_RKIND,0.2_RKIND,.true.,eps,rmin,rmax),1.5_RKIND),'plain ratio')
 call check(aod_ratio(0.3_RKIND,0.2_RKIND,.false.,eps,rmin,rmax) == 1._RKIND,'invalid observation leaves 1')
 call check(aod_ratio(AOD_FILL,0.2_RKIND,.true.,eps,rmin,rmax) == 1._RKIND,'fill leaves 1 even if marked valid')
 call check(aod_ratio(0.3_RKIND,0.005_RKIND,.true.,eps,rmin,rmax) == 1._RKIND,'model AOD below eps leaves 1')
 call check(aod_ratio(0.3_RKIND,eps,.true.,eps,rmin,rmax) > 1._RKIND,'model AOD equal to eps is scaled')
 call check(aod_ratio(5._RKIND,0.02_RKIND,.true.,eps,rmin,rmax) == rmax,'upper limit')
 call check(aod_ratio(0.001_RKIND,0.5_RKIND,.true.,eps,rmin,rmax) == rmin,'lower limit')
 call check(aod_ratio(0._RKIND,0.5_RKIND,.true.,eps,rmin,rmax) == rmin,'zero observation gives the lower limit')
 r = aod_ratio((/0.1_RKIND,0.4_RKIND,AOD_FILL/),0.2_RKIND,.true.,eps,rmin,rmax)
 call check(near(r(1),0.5_RKIND) .and. near(r(2),2._RKIND) .and. r(3) == 1._RKIND,'elemental over columns')
 end subroutine test_ratio

 subroutine test_tropospheric_ratio()
 real(kind=RKIND):: r,total,eligible,fixed
 total = 0.30_RKIND ; eligible = 0.25_RKIND ; fixed = total-eligible
!--- the analyzed column, fixed + ratio*eligible, reproduces the observation:
 r = aod_tropospheric_ratio(0.45_RKIND,total,eligible,.true.,eps,rmin,rmax)
 call check(near(fixed+r*eligible,0.45_RKIND),'tropospheric ratio closes on the observation')
 call check(near(r,1.6_RKIND),'tropospheric ratio value')
!--- an observation below the fixed part cannot be matched:
 r = aod_tropospheric_ratio(0.03_RKIND,total,eligible,.true.,eps,rmin,rmax)
 call check(r == rmin,'observation below the fixed AOD gives the lower limit')
!--- eps applies to the eligible part, not to the column:
 r = aod_tropospheric_ratio(0.5_RKIND,0.30_RKIND,0.005_RKIND,.true.,eps,rmin,rmax)
 call check(r == 1._RKIND,'eligible AOD below eps leaves 1')
 r = aod_tropospheric_ratio(AOD_FILL,total,eligible,.true.,eps,rmin,rmax)
 call check(r == 1._RKIND,'fill leaves 1')
 r = aod_tropospheric_ratio(0.45_RKIND,total,eligible,.false.,eps,rmin,rmax)
 call check(r == 1._RKIND,'invalid observation leaves 1')
!--- with the whole column eligible it is the plain ratio:
 r = aod_tropospheric_ratio(0.45_RKIND,total,total,.true.,eps,rmin,rmax)
 call check(near(r,aod_ratio(0.45_RKIND,total,.true.,eps,rmin,rmax)),'whole column eligible')
 end subroutine test_tropospheric_ratio

 subroutine test_layers()
 real(kind=RKIND):: ple(6)
 ple = (/1000._RKIND,5000._RKIND,15000._RKIND,40000._RKIND,80000._RKIND,100000._RKIND/)
 call check(tropopause_layer(ple,20000._RKIND) == 3,'pressure inside layer 3')
 call check(tropopause_layer(ple,15000._RKIND) == 2,'pressure on an edge belongs to the layer above it')
 call check(tropopause_layer(ple,100000._RKIND) == 5,'pressure at the surface')
 call check(tropopause_layer(ple,1000._RKIND) == 0,'pressure at the model top is not usable')
 call check(tropopause_layer(ple,500._RKIND) == 0,'pressure above the model top is not usable')
 call check(tropopause_layer(ple,100001._RKIND) == 0,'pressure below the surface is not usable')
 call check(tropopause_layer(ple,0._RKIND) == 0,'zero is not usable')
 call check(tropopause_layer(ple,AOD_FILL) == 0,'negative is not usable')
 call check(.not. below_tropopause(3,3,5),'the tropopause layer is protected')
 call check(.not. below_tropopause(1,3,5),'layers above are protected')
 call check(below_tropopause(4,3,5) .and. below_tropopause(5,3,5),'layers below are eligible')
 call check(.not. any(below_tropopause((/1,2,3,4,5/),0,5)),'no tropopause, no eligible layer')
 call check(.not. any(below_tropopause((/1,2,3,4,5/),6,5)),'tropopause layer out of range, no eligible layer')
 end subroutine test_layers

 subroutine test_partition()
 real(kind=RKIND):: tau(5),total,eligible
 tau = (/0.01_RKIND,0.02_RKIND,0.03_RKIND,0.10_RKIND,0.20_RKIND/)
 call partition_optical_depth(tau,3,.true.,total,eligible)
 call check(near(total,0.36_RKIND) .and. near(eligible,0.30_RKIND),'tropospheric partition')
 call partition_optical_depth(tau,3,.false.,total,eligible)
 call check(near(total,0.36_RKIND) .and. near(eligible,0.36_RKIND),'whole-column partition')
 call partition_optical_depth(tau,0,.true.,total,eligible)
 call check(near(total,0.36_RKIND) .and. eligible == 0._RKIND,'no tropopause, nothing eligible')
 call partition_optical_depth(tau,5,.true.,total,eligible)
 call check(eligible == 0._RKIND,'tropopause in the lowest layer, nothing eligible')
 end subroutine test_partition

 subroutine test_time()
 real(kind=RKIND):: target_aod
 logical:: valid
 call check(near(interp_weight(5400._RKIND,0._RKIND,10800._RKIND),0.5_RKIND),'weight at the midpoint')
 call check(interp_weight(-10._RKIND,0._RKIND,10800._RKIND) == 0._RKIND,'weight before the first snapshot')
 call check(interp_weight(20000._RKIND,0._RKIND,10800._RKIND) == 1._RKIND,'weight after the second snapshot')
 call check(interp_weight(5._RKIND,10._RKIND,10._RKIND) == 0._RKIND,'coincident snapshots')
 call combine_snapshots(0.2_RKIND,0.4_RKIND,.true.,.true.,0.25_RKIND,target_aod,valid)
 call check(valid .and. near(target_aod,0.25_RKIND),'both snapshots valid: interpolate')
 call combine_snapshots(0.2_RKIND,AOD_FILL,.true.,.false.,0.25_RKIND,target_aod,valid)
 call check(valid .and. near(target_aod,0.2_RKIND),'only the earlier snapshot valid')
 call combine_snapshots(AOD_FILL,0.4_RKIND,.false.,.true.,0.25_RKIND,target_aod,valid)
 call check(valid .and. near(target_aod,0.4_RKIND),'only the later snapshot valid')
 call combine_snapshots(AOD_FILL,AOD_FILL,.false.,.false.,0.25_RKIND,target_aod,valid)
 call check((.not. valid) .and. target_aod == AOD_FILL,'neither snapshot valid')
 end subroutine test_time

 end program test_aod_kernel
