!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Timing routines for accounting
!> \par History
!>      02.2004 made a stacked version (of stacks...) [Joost VandeVondele]
!>      11.2004 storable timer_envs (for f77 interface) [fawzi]
!>      10.2005 binary search to speed up lookup in timeset [fawzi]
!>      12.2012 Complete rewrite based on dictionaries. [ole]
!> \author JGH
! **************************************************************************************************
MODULE timings
   USE base_hooks,                      ONLY: timeset_hook,&
                                              timestop_hook
   USE callgraph,                       ONLY: callgraph_destroy,&
                                              callgraph_get,&
                                              callgraph_init,&
                                              callgraph_item_type,&
                                              callgraph_items,&
                                              callgraph_set
   USE kinds,                           ONLY: default_string_length,&
                                              dp,&
                                              int_8
   USE list,                            ONLY: &
        list_destroy, list_get, list_init, list_isready, list_peek, list_pop, list_push, &
        list_size, list_timerenv_type
   USE machine,                         ONLY: m_energy,&
                                              m_flush,&
                                              m_memory,&
                                              m_walltime
   USE offload_api,                     ONLY: offload_mem_info,&
                                              offload_timeset,&
                                              offload_timestop
   USE routine_map,                     ONLY: routine_map_destroy,&
                                              routine_map_get,&
                                              routine_map_init,&
                                              routine_map_set,&
                                              routine_map_size
   USE timings_base_type,               ONLY: call_stat_type,&
                                              callstack_entry_type,&
                                              routine_stat_type
   USE timings_types,                   ONLY: timer_env_type
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: print_stack, timings_register_hooks

   ! these routines are currently only used by environment.F and f77_interface.F
   PUBLIC :: add_timer_env, rm_timer_env, get_timer_env
   PUBLIC :: timer_env_retain, timer_env_release
   PUBLIC :: timings_setup_tracing

   ! global variables
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'timings'
   TYPE(list_timerenv_type), SAVE, PRIVATE                  :: timers_stack

   !API (via pointer assignment to hook, PR67982, not meant to be called directly)
   PUBLIC :: timeset_handler, timestop_handler

   INTEGER, PUBLIC, PARAMETER :: default_timings_level = 1
   INTEGER, PUBLIC, SAVE :: global_timings_level = default_timings_level

   CHARACTER(LEN=default_string_length), PUBLIC, PARAMETER :: root_cp2k_name = 'CP2K'

CONTAINS

! **************************************************************************************************
!> \brief Registers handlers with base_hooks.F
!> \author Ole Schuett
! **************************************************************************************************
   SUBROUTINE timings_register_hooks()
      timeset_hook => timeset_handler
      timestop_hook => timestop_handler
   END SUBROUTINE timings_register_hooks

! **************************************************************************************************
!> \brief adds the given timer_env to the top of the stack
!> \param timer_env ...
!> \par History
!>      02.2004 created [Joost VandeVondele]
!> \note
!>      for each init_timer_env there should be the symmetric call to
!>      rm_timer_env
! **************************************************************************************************
   SUBROUTINE add_timer_env(timer_env)
      TYPE(timer_env_type), OPTIONAL, POINTER            :: timer_env

      TYPE(timer_env_type), POINTER                      :: timer_env_

      IF (PRESENT(timer_env)) timer_env_ => timer_env
      IF (.NOT. PRESENT(timer_env)) CALL timer_env_create(timer_env_)
      IF (.NOT. ASSOCIATED(timer_env_)) &
         CPABORT("add_timer_env: not associated")

      CALL timer_env_retain(timer_env_)
      IF (.NOT. list_isready(timers_stack)) CALL list_init(timers_stack)
      CALL list_push(timers_stack, timer_env_)
   END SUBROUTINE add_timer_env

! **************************************************************************************************
!> \brief creates a new timer env
!> \param timer_env ...
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE timer_env_create(timer_env)
      TYPE(timer_env_type), POINTER                      :: timer_env

      ALLOCATE (timer_env)
      timer_env%ref_count = 0
      timer_env%trace_max = -1 ! tracing disabled by default
      timer_env%trace_all = .FALSE.
      CALL routine_map_init(timer_env%routine_names)
      CALL callgraph_init(timer_env%callgraph)
      CALL list_init(timer_env%routine_stats)
      CALL list_init(timer_env%callstack)
   END SUBROUTINE timer_env_create

! **************************************************************************************************
!> \brief removes the current timer env from the stack
!> \par History
!>      02.2004 created [Joost VandeVondele]
!> \note
!>      for each rm_timer_env there should have been the symmetric call to
!>      add_timer_env
! **************************************************************************************************
   SUBROUTINE rm_timer_env()
      TYPE(timer_env_type), POINTER                      :: timer_env

      timer_env => list_pop(timers_stack)
      CALL timer_env_release(timer_env)
      IF (list_size(timers_stack) == 0) CALL list_destroy(timers_stack)
   END SUBROUTINE rm_timer_env

! **************************************************************************************************
!> \brief returns the current timer env from the stack
!> \return ...
!> \author fawzi
! **************************************************************************************************
   FUNCTION get_timer_env() RESULT(timer_env)
      TYPE(timer_env_type), POINTER                      :: timer_env

      timer_env => list_peek(timers_stack)
   END FUNCTION get_timer_env

! **************************************************************************************************
!> \brief retains the given timer env
!> \param timer_env the timer env to retain
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE timer_env_retain(timer_env)
      TYPE(timer_env_type), POINTER                      :: timer_env

      IF (.NOT. ASSOCIATED(timer_env)) &
         CPABORT("timer_env_retain: not associated")
      IF (timer_env%ref_count < 0) &
         CPABORT("timer_env_retain: negativ ref_count")
      timer_env%ref_count = timer_env%ref_count + 1
   END SUBROUTINE timer_env_retain

! **************************************************************************************************
!> \brief releases the given timer env
!> \param timer_env the timer env to release
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE timer_env_release(timer_env)
      TYPE(timer_env_type), POINTER                      :: timer_env

      INTEGER                                            :: i
      TYPE(callgraph_item_type), DIMENSION(:), POINTER   :: ct_items
      TYPE(routine_stat_type), POINTER                   :: r_stat

      IF (.NOT. ASSOCIATED(timer_env)) &
         CPABORT("timer_env_release: not associated")
      IF (timer_env%ref_count < 0) &
         CPABORT("timer_env_release: negativ ref_count")
      timer_env%ref_count = timer_env%ref_count - 1
      IF (timer_env%ref_count > 0) RETURN

      ! No more references left - let's tear down this timer_env...

      DO i = 1, list_size(timer_env%routine_stats)
         r_stat => list_get(timer_env%routine_stats, i)
         DEALLOCATE (r_stat)
      END DO

      ct_items => callgraph_items(timer_env%callgraph)
      DO i = 1, SIZE(ct_items)
         DEALLOCATE (ct_items(i)%value)
      END DO
      DEALLOCATE (ct_items)

      CALL routine_map_destroy(timer_env%routine_names)
      CALL callgraph_destroy(timer_env%callgraph)
      CALL list_destroy(timer_env%callstack)
      CALL list_destroy(timer_env%routine_stats)
      DEALLOCATE (timer_env)
   END SUBROUTINE timer_env_release

! **************************************************************************************************
!> \brief Start timer
!> \param routineN ...
!> \param handle ...
!> \par History
!>      none
!> \author JGH
! **************************************************************************************************
   SUBROUTINE timeset_handler(routineN, handle)
      CHARACTER(LEN=*), INTENT(IN)                       :: routineN
      INTEGER, INTENT(OUT)                               :: handle

      CHARACTER(LEN=400)                                 :: line, mystring
      CHARACTER(LEN=60)                                  :: sformat
      CHARACTER(LEN=default_string_length)               :: routine_name_dsl
      INTEGER                                            :: routine_id, stack_size
      INTEGER(KIND=int_8)                                :: cpumem, gpumem_free, gpumem_total
      INTEGER, SAVE                                      :: root_cp2k_id
      TYPE(callstack_entry_type)                         :: cs_entry
      TYPE(routine_stat_type), POINTER                   :: r_stat
      TYPE(timer_env_type), POINTER                      :: timer_env

!$OMP MASTER

      ! Default value, using a negative value when timing is not taken
      cs_entry%walltime_start = -HUGE(1.0_dp)
      cs_entry%energy_start = -HUGE(1.0_dp)
      root_cp2k_id = routine_name2id(root_cp2k_name)
      !
      routine_name_dsl = routineN ! converte to default_string_length
      routine_id = routine_name2id(routine_name_dsl)
      !
      ! Take timings when the timings_level is appropriated
      IF (global_timings_level .NE. 0 .OR. routine_id .EQ. root_cp2k_id) THEN
         cs_entry%walltime_start = m_walltime()
         cs_entry%energy_start = m_energy()
      END IF
      timer_env => list_peek(timers_stack)

      IF (LEN_TRIM(routineN) > default_string_length) THEN
         CPABORT('timings_timeset: routineN too long: "'//TRIM(routineN)//"'")
      END IF

      ! update routine r_stats
      r_stat => list_get(timer_env%routine_stats, routine_id)
      stack_size = list_size(timer_env%callstack)
      r_stat%total_calls = r_stat%total_calls + 1
      r_stat%active_calls = r_stat%active_calls + 1
      r_stat%stackdepth_accu = r_stat%stackdepth_accu + stack_size + 1

      ! add routine to callstack
      cs_entry%routine_id = routine_id
      CALL list_push(timer_env%callstack, cs_entry)

      !..if debug mode echo the subroutine name
      IF ((timer_env%trace_all .OR. r_stat%trace) .AND. &
          (r_stat%total_calls < timer_env%trace_max)) THEN
         WRITE (sformat, *) "(A,A,", MAX(1, 3*stack_size - 4), "X,I4,1X,I6,1X,A,A)"
         WRITE (mystring, sformat) timer_env%trace_str, ">>", stack_size + 1, &
            r_stat%total_calls, TRIM(r_stat%routineN), "       start"
         CALL offload_mem_info(gpumem_free, gpumem_total)
         CALL m_memory(cpumem)
         WRITE (line, '(A,A,I0,A,A,I0,A)') TRIM(mystring), &
            " Hostmem: ", (cpumem + 1024*1024 - 1)/(1024*1024), " MB", &
            " GPUmem: ", (gpumem_total - gpumem_free)/(1024*1024), " MB"
         WRITE (timer_env%trace_unit, *) TRIM(line)
         CALL m_flush(timer_env%trace_unit)
      END IF

      handle = routine_id

      CALL offload_timeset(routineN)

!$OMP END MASTER

   END SUBROUTINE timeset_handler

! **************************************************************************************************
!> \brief End timer
!> \param handle ...
!> \par History
!>      none
!> \author JGH
! **************************************************************************************************
   SUBROUTINE timestop_handler(handle)
      INTEGER, INTENT(in)                                :: handle

      CHARACTER(LEN=400)                                 :: line, mystring
      CHARACTER(LEN=60)                                  :: sformat
      INTEGER                                            :: routine_id, stack_size
      INTEGER(KIND=int_8)                                :: cpumem, gpumem_free, gpumem_total
      INTEGER, DIMENSION(2)                              :: routine_tuple
      REAL(KIND=dp)                                      :: en_elapsed, en_now, wt_elapsed, wt_now
      TYPE(call_stat_type), POINTER                      :: c_stat
      TYPE(callstack_entry_type)                         :: cs_entry, prev_cs_entry
      TYPE(routine_stat_type), POINTER                   :: prev_stat, r_stat
      TYPE(timer_env_type), POINTER                      :: timer_env

      routine_id = handle

!$OMP MASTER

      CALL offload_timestop()

      timer_env => list_peek(timers_stack)
      cs_entry = list_pop(timer_env%callstack)
      r_stat => list_get(timer_env%routine_stats, cs_entry%routine_id)

      IF (handle /= cs_entry%routine_id) THEN
         PRINT *, "list_size(timer_env%callstack) ", list_size(timer_env%callstack), &
            " handle ", handle, " list_size(timers_stack) ", list_size(timers_stack)
         CPABORT('mismatched timestop '//TRIM(r_stat%routineN)//' in routine timestop')
      END IF

      wt_elapsed = 0
      en_elapsed = 0
      ! Take timings only when the start time is >=0, i.e. the timings_level is appropriated
      IF (cs_entry%walltime_start .GE. 0) THEN
         wt_now = m_walltime()
         en_now = m_energy()
         ! add the elapsed time for this timeset/timestop to the time accumulator
         wt_elapsed = wt_now - cs_entry%walltime_start
         en_elapsed = en_now - cs_entry%energy_start
      END IF
      r_stat%active_calls = r_stat%active_calls - 1

      ! if we're the last instance in the stack, we do the accounting of the total time
      IF (r_stat%active_calls == 0) THEN
         r_stat%incl_walltime_accu = r_stat%incl_walltime_accu + wt_elapsed
         r_stat%incl_energy_accu = r_stat%incl_energy_accu + en_elapsed
      END IF

      ! exclusive time we always sum, since children will correct this time with their total time
      r_stat%excl_walltime_accu = r_stat%excl_walltime_accu + wt_elapsed
      r_stat%excl_energy_accu = r_stat%excl_energy_accu + en_elapsed

      stack_size = list_size(timer_env%callstack)
      IF (stack_size > 0) THEN
         prev_cs_entry = list_peek(timer_env%callstack)
         prev_stat => list_get(timer_env%routine_stats, prev_cs_entry%routine_id)
         ! we fixup the clock of the caller
         prev_stat%excl_walltime_accu = prev_stat%excl_walltime_accu - wt_elapsed
         prev_stat%excl_energy_accu = prev_stat%excl_energy_accu - en_elapsed

         !update callgraph
         routine_tuple = (/prev_cs_entry%routine_id, routine_id/)
         c_stat => callgraph_get(timer_env%callgraph, routine_tuple, default_value=Null(c_stat))
         IF (.NOT. ASSOCIATED(c_stat)) THEN
            ALLOCATE (c_stat)
            c_stat%total_calls = 0
            c_stat%incl_walltime_accu = 0.0_dp
            c_stat%incl_energy_accu = 0.0_dp
            CALL callgraph_set(timer_env%callgraph, routine_tuple, c_stat)
         END IF
         c_stat%total_calls = c_stat%total_calls + 1
         c_stat%incl_walltime_accu = c_stat%incl_walltime_accu + wt_elapsed
         c_stat%incl_energy_accu = c_stat%incl_energy_accu + en_elapsed
      END IF

      !..if debug mode echo the subroutine name
      IF ((timer_env%trace_all .OR. r_stat%trace) .AND. &
          (r_stat%total_calls < timer_env%trace_max)) THEN
         WRITE (sformat, *) "(A,A,", MAX(1, 3*stack_size - 4), "X,I4,1X,I6,1X,A,F12.3)"
         WRITE (mystring, sformat) timer_env%trace_str, "<<", stack_size + 1, &
            r_stat%total_calls, TRIM(r_stat%routineN), wt_elapsed
         CALL offload_mem_info(gpumem_free, gpumem_total)
         CALL m_memory(cpumem)
         WRITE (line, '(A,A,I0,A,A,I0,A)') TRIM(mystring), &
            " Hostmem: ", (cpumem + 1024*1024 - 1)/(1024*1024), " MB", &
            " GPUmem: ", (gpumem_total - gpumem_free)/(1024*1024), " MB"
         WRITE (timer_env%trace_unit, *) TRIM(line)
         CALL m_flush(timer_env%trace_unit)
      END IF

!$OMP END MASTER

   END SUBROUTINE timestop_handler

! **************************************************************************************************
!> \brief Set routine tracer
!> \param trace_max  maximum number of calls reported per routine.
!>           Setting this to zero disables tracing.
!> \param unit_nr output unit used for printing the trace-messages
!> \param trace_str short info-string which is printed along with every message
!> \param routine_names List of routine-names.
!>                     If provided only these routines will be traced.
!>                     If not present all routines will traced.
!> \par History
!>       12.2012  added ability to trace only certain routines [ole]
!> \author JGH
! **************************************************************************************************
   SUBROUTINE timings_setup_tracing(trace_max, unit_nr, trace_str, routine_names)
      INTEGER, INTENT(IN)                                :: trace_max, unit_nr
      CHARACTER(len=13), INTENT(IN)                      :: trace_str
      CHARACTER(len=default_string_length), &
         DIMENSION(:), INTENT(IN), OPTIONAL              :: routine_names

      INTEGER                                            :: i, routine_id
      TYPE(routine_stat_type), POINTER                   :: r_stat
      TYPE(timer_env_type), POINTER                      :: timer_env

      timer_env => list_peek(timers_stack)
      timer_env%trace_max = trace_max
      timer_env%trace_unit = unit_nr
      timer_env%trace_str = trace_str
      timer_env%trace_all = .TRUE.
      IF (.NOT. PRESENT(routine_names)) RETURN

      ! setup routine-specific tracing
      timer_env%trace_all = .FALSE.
      DO i = 1, SIZE(routine_names)
         routine_id = routine_name2id(routine_names(i))
         r_stat => list_get(timer_env%routine_stats, routine_id)
         r_stat%trace = .TRUE.
      END DO

   END SUBROUTINE timings_setup_tracing

! **************************************************************************************************
!> \brief Print current routine stack
!> \param unit_nr ...
!> \par History
!>      none
!> \author JGH
! **************************************************************************************************
   SUBROUTINE print_stack(unit_nr)
      INTEGER, INTENT(IN)                                :: unit_nr

      INTEGER                                            :: i
      TYPE(callstack_entry_type)                         :: cs_entry
      TYPE(routine_stat_type), POINTER                   :: r_stat
      TYPE(timer_env_type), POINTER                      :: timer_env

      ! catch edge cases where timer_env is not yet/anymore available
      IF (.NOT. list_isready(timers_stack)) &
         RETURN
      IF (list_size(timers_stack) == 0) &
         RETURN

      timer_env => list_peek(timers_stack)
      WRITE (unit_nr, '(/,A,/)') " ===== Routine Calling Stack ===== "
      DO i = list_size(timer_env%callstack), 1, -1
         cs_entry = list_get(timer_env%callstack, i)
         r_stat => list_get(timer_env%routine_stats, cs_entry%routine_id)
         WRITE (unit_nr, '(T10,I4,1X,A)') i, TRIM(r_stat%routineN)
      END DO
      CALL m_flush(unit_nr)

   END SUBROUTINE print_stack

! **************************************************************************************************
!> \brief Internal routine used by timestet and timings_setup_tracing.
!>        If no routine with given name is found in timer_env%routine_names
!>        then a new entiry is created.
!> \param routineN ...
!> \return ...
!> \author Ole Schuett
! **************************************************************************************************
   FUNCTION routine_name2id(routineN) RESULT(routine_id)
      CHARACTER(LEN=default_string_length), INTENT(IN)   :: routineN
      INTEGER                                            :: routine_id

      TYPE(routine_stat_type), POINTER                   :: r_stat
      TYPE(timer_env_type), POINTER                      :: timer_env

      timer_env => list_peek(timers_stack)
      routine_id = routine_map_get(timer_env%routine_names, routineN, default_value=-1)

      IF (routine_id /= -1) RETURN ! found an id - let's return it
      ! routine not found - let's create it

      ! enforce space free timer names, to make the output of trace/timings of a fixed number fields
      IF (INDEX(routineN(1:LEN_TRIM(routineN)), ' ') /= 0) THEN
         CPABORT("timings_name2id: routineN contains spaces: "//routineN)
      END IF

      ! register routine_name_dsl with new routine_id
      routine_id = routine_map_size(timer_env%routine_names) + 1
      CALL routine_map_set(timer_env%routine_names, routineN, routine_id)

      ALLOCATE (r_stat)
      r_stat%routine_id = routine_id
      r_stat%routineN = routineN
      r_stat%active_calls = 0
      r_stat%excl_walltime_accu = 0.0_dp
      r_stat%incl_walltime_accu = 0.0_dp
      r_stat%excl_energy_accu = 0.0_dp
      r_stat%incl_energy_accu = 0.0_dp
      r_stat%total_calls = 0
      r_stat%stackdepth_accu = 0
      r_stat%trace = .FALSE.
      CALL list_push(timer_env%routine_stats, r_stat)
      CPASSERT(list_size(timer_env%routine_stats) == routine_map_size(timer_env%routine_names))
   END FUNCTION routine_name2id

END MODULE timings

