!=================================================================================================================
 module mpas_chemistry_gocart2G_aod_obs
!=================================================================================================================
! Observations for the AOD constraint. Reads, through the stream manager, the two records of the aod_obs
! stream that surround the current time, and keeps them with the weight needed to interpolate between them.
! The records are 3-hour windows stamped with the window center; a cell without a valid retrieval holds a
! negative value. A record that cannot be read, or that is more than one window away, counts as "no
! observation": the model then runs free.

 use mpas_log
 use mpas_kind_types
 use mpas_derived_types
 use mpas_pool_routines,only: mpas_pool_get_config,mpas_pool_get_subpool,mpas_pool_get_dimension, &
                              mpas_pool_get_array
 use mpas_timekeeping
 use mpas_stream_manager

 use mpas_chemistry_gocart2G_aod_kernel,only: interp_weight,AOD_FILL

 implicit none
 private
 public:: aod_obs_update

 character(len=*),parameter,public:: aod_obs_streamID = 'aod_obs'

!--- length of an observation window [s]. A record further than this from the current time is not used.
 real(kind=RKIND),parameter,public:: aod_obs_window = 10800._RKIND

!--- set by aod_obs_update and used by the constraint at the end of the same time step:
 logical,public:: aod_apply_now         = .false.  ! the constraint is due in this time step
 logical,public:: aod_obs_before_usable = .false.  ! aod_obs_before holds a record close enough in time
 logical,public:: aod_obs_after_usable  = .false.  ! aod_obs_after holds a record close enough in time
 real(kind=RKIND),public:: aod_obs_weight = 0._RKIND  ! weight of aod_obs_after in the interpolation


 contains


!=================================================================================================================
 subroutine aod_obs_update(domain,clock,stream_manager)
!=================================================================================================================

!--- inout arguments:
 type(domain_type),intent(inout):: domain
 type(MPAS_Clock_type),intent(in):: clock
 type(MPAS_streamManager_type),intent(inout):: stream_manager

!--- local variables and pointers:
 type(MPAS_Time_Type):: currTime,beforeTime,afterTime
 type(MPAS_TimeInterval_Type):: delta

 character(len=StrKIND):: beforeStamp,afterStamp

 real(kind=RKIND),pointer:: config_dt
 real(kind=RKIND):: before_age,after_age,span

 integer:: ierr

!-----------------------------------------------------------------------------------------------------------------
 call mpas_log_write(' ')
 call mpas_log_write('--- enter subroutine aod_obs_update:')

 aod_apply_now         = .true.
 aod_obs_before_usable = .false.
 aod_obs_after_usable  = .false.
 aod_obs_weight        = 0._RKIND
 before_age = 0._RKIND
 after_age  = 0._RKIND

 currTime = mpas_get_clock_time(clock,MPAS_NOW,ierr)
 call mpas_pool_get_config(domain%blocklist%configs,'config_dt',config_dt)

!--- record at or before the current time:
 beforeStamp = ' '
 call mpas_stream_mgr_read(stream_manager,aod_obs_streamID,rightNow=.true., &
                           whence=MPAS_STREAM_LATEST_BEFORE,actualWhen=beforeStamp,ierr=ierr)
 if(ierr == MPAS_STREAM_MGR_NOERR .and. len_trim(beforeStamp) > 0) then
    call mpas_set_time(beforeTime,dateTimeString=trim(beforeStamp))
    delta = currTime - beforeTime
    call mpas_get_timeInterval(delta,dt=before_age)
    aod_obs_before_usable = before_age >= 0._RKIND .and. before_age <= aod_obs_window
    call mpas_log_write('    observation record at or before now: '//trim(beforeStamp))
 else
    call mpas_log_write('    no observation record at or before now')
 endif
 call copy_record(domain,'aod_obs_before',aod_obs_before_usable)

!--- record at or after the current time:
 afterStamp = ' '
 call mpas_stream_mgr_read(stream_manager,aod_obs_streamID,rightNow=.true., &
                           whence=MPAS_STREAM_EARLIEST_AFTER,actualWhen=afterStamp,ierr=ierr)
 if(ierr == MPAS_STREAM_MGR_NOERR .and. len_trim(afterStamp) > 0) then
    call mpas_set_time(afterTime,dateTimeString=trim(afterStamp))
    delta = afterTime - currTime
    call mpas_get_timeInterval(delta,dt=after_age)
    aod_obs_after_usable = after_age >= 0._RKIND .and. after_age <= aod_obs_window
    call mpas_log_write('    observation record at or after now:  '//trim(afterStamp))
 else
    call mpas_log_write('    no observation record at or after now')
 endif
 call copy_record(domain,'aod_obs_after',aod_obs_after_usable)

!--- the constraint acts on the state at the end of the time step, so the two records are weighted for that
!    time. interp_weight keeps the weight between 0 and 1.
 if(aod_obs_before_usable .and. aod_obs_after_usable) then
    span = before_age + after_age
    aod_obs_weight = interp_weight(before_age+config_dt,0._RKIND,span)
 endif

 if(.not. (aod_obs_before_usable .or. aod_obs_after_usable)) then
    call mpas_log_write('AOD constraint: no observation record within one window of the current time; '// &
                        'the aerosol is not constrained in this time step.',messageType=MPAS_LOG_WARN)
 endif
 call mpas_log_write('    weight of the later record = $r',realArgs=(/aod_obs_weight/))
 call mpas_log_write('--- end subroutine aod_obs_update.')

 end subroutine aod_obs_update

!=================================================================================================================
 subroutine copy_record(domain,destination,usable)
!=================================================================================================================
! Copy the record just read into AOD_mean to one of the two snapshots, in every block. An unusable record
! is stored as "no observation".

!--- input arguments:
 type(domain_type),intent(inout):: domain
 character(len=*),intent(in):: destination
 logical,intent(in):: usable

!--- local variables and pointers:
 type(block_type),pointer:: block
 type(mpas_pool_type),pointer:: aod_constraint
 real(kind=RKIND),dimension(:),pointer:: aod_mean,snapshot

!-----------------------------------------------------------------------------------------------------------------

 block => domain%blocklist
 do while(associated(block))
    call mpas_pool_get_subpool(block%structs,'gocart2G_aod_constraint',aod_constraint)
    call mpas_pool_get_array(aod_constraint,'AOD_mean',aod_mean)
    call mpas_pool_get_array(aod_constraint,trim(destination),snapshot)
    if(usable) then
       snapshot(:) = aod_mean(:)
    else
       snapshot(:) = AOD_FILL
    endif
    block => block%next
 enddo

 end subroutine copy_record

!=================================================================================================================
 end module mpas_chemistry_gocart2G_aod_obs
!=================================================================================================================
