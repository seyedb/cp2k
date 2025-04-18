!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief interpolate the wavefunctions to speed up the convergence when
!>      doing MD
!> \par History
!>      12.2002 created [fawzi]
!>      02.2005 wf_mol added [MI]
!> \author fawzi
! **************************************************************************************************
MODULE qs_wf_history_types
   USE cp_dbcsr_api,                    ONLY: dbcsr_deallocate_matrix,&
                                              dbcsr_p_type,&
                                              dbcsr_type
   USE cp_dbcsr_operations,             ONLY: dbcsr_deallocate_matrix_set
   USE cp_fm_types,                     ONLY: cp_fm_release,&
                                              cp_fm_type
   USE kinds,                           ONLY: dp
   USE pw_types,                        ONLY: pw_c1d_gs_type,&
                                              pw_r3d_rs_type
   USE qs_rho_types,                    ONLY: qs_rho_release,&
                                              qs_rho_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_wf_history_types'

   PUBLIC :: qs_wf_snapshot_type, &
             qs_wf_history_type, qs_wf_history_p_type
   PUBLIC :: wfi_retain, wfi_release, wfi_get_snapshot

! **************************************************************************************************
!> \brief represent a past snapshot of the wavefunction.
!>      some elements might not be associated (to spare memory)
!>      depending on how the snapshot was taken
!> \param wf the wavefunctions
!> \param rho_r the density in r space
!> \param rho_g the density in g space
!> \param rho_ao the density in ao space
!> \param overlap the overlap matrix
!> \param rho_frozen the frozen density structure
!> \param dt the time of the snapshot (wrf to te previous snapshot!)
!> \note
!>      keep track also of occupation numbers and energies?
!> \par History
!>      02.2003 created [fawzi]
!>      02.2005 wf_mol added [MI]
!> \author fawzi
! **************************************************************************************************
   TYPE qs_wf_snapshot_type
      TYPE(cp_fm_type), DIMENSION(:), POINTER :: wf => NULL()
      TYPE(pw_r3d_rs_type), DIMENSION(:), POINTER :: rho_r => NULL()
      TYPE(pw_c1d_gs_type), DIMENSION(:), POINTER :: rho_g => NULL()
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER :: rho_ao => NULL()
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER :: rho_ao_kp => NULL()
      TYPE(dbcsr_type), POINTER :: overlap => NULL()
      TYPE(qs_rho_type), POINTER :: rho_frozen => NULL()
      REAL(KIND=dp) :: dt = 0.0_dp
   END TYPE qs_wf_snapshot_type

! **************************************************************************************************
!> \brief pointer to a snapshot
!> \param snapshot the pointer to the snapshot
!> \par History
!>      02.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   TYPE qs_wf_snapshot_p_type
      TYPE(qs_wf_snapshot_type), POINTER :: snapshot => NULL()
   END TYPE qs_wf_snapshot_p_type

! **************************************************************************************************
!> \brief keeps track of the previous wavefunctions and can extrapolate them
!>      for the next step of md
!> \param ref_cont reference count (see doc/ReferenceCounting.html)
!> \param memory_depth how many snapshots should be stored
!> \param last_state_index index of the latest snapshot
!> \param past_states array with the past states (index starts at
!>        last_state_index)
!> \param interpolation_method_nr the tag of the method used to
!>        extrapolate the new start state for qs
!> \param snapshot_count number of snapshot taken so far (cumulative,
!>        can be bigger than the history depth)
!> \note
!>      use a linked list for the past states ?
!> \par History
!>      02.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   TYPE qs_wf_history_type
      INTEGER :: ref_count = -1, memory_depth = -1, last_state_index = -1, &
                 interpolation_method_nr = -1, snapshot_count = -1
      LOGICAL :: store_wf = .FALSE., store_rho_r = .FALSE., store_rho_g = .FALSE., &
                 store_rho_ao = .FALSE., store_rho_ao_kp = .FALSE., &
                 store_overlap = .FALSE., store_frozen_density = .FALSE.
      TYPE(qs_wf_snapshot_p_type), DIMENSION(:), POINTER :: past_states => NULL()
   END TYPE qs_wf_history_type

! **************************************************************************************************
!> \brief to create arrays of pointers to qs_wf_history_type
!> \param wf_hist the pointer to the wf history
!> \author fawzi
! **************************************************************************************************
   TYPE qs_wf_history_p_type
      TYPE(qs_wf_history_type), POINTER :: wf_history => NULL()
   END TYPE qs_wf_history_p_type

CONTAINS

! **************************************************************************************************
!> \brief releases a snapshot of a wavefunction (see doc/ReferenceCounting.html)
!> \param snapshot the snapshot to release
!> \par History
!>      02.2003 created [fawzi]
!>      02.2005 wf_mol added [MI]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE wfs_release(snapshot)
      TYPE(qs_wf_snapshot_type), INTENT(INOUT)           :: snapshot

      CALL cp_fm_release(snapshot%wf)
      ! snapshot%rho_r & snapshot%rho_g is deallocated in wfs_update
      ! of qs_wf_history_methods, in case you wonder about it.
      IF (ASSOCIATED(snapshot%rho_ao)) THEN
         CALL dbcsr_deallocate_matrix_set(snapshot%rho_ao)
      END IF
      IF (ASSOCIATED(snapshot%rho_ao_kp)) THEN
         CALL dbcsr_deallocate_matrix_set(snapshot%rho_ao_kp)
      END IF
      IF (ASSOCIATED(snapshot%overlap)) THEN
         CALL dbcsr_deallocate_matrix(snapshot%overlap)
      END IF
      IF (ASSOCIATED(snapshot%rho_frozen)) THEN
         CALL qs_rho_release(snapshot%rho_frozen)
         DEALLOCATE (snapshot%rho_frozen)
      END IF

   END SUBROUTINE wfs_release

! **************************************************************************************************
!> \brief retains a wf history (see doc/ReferenceCounting.html)
!> \param wf_history the wf_history to retain
!> \par History
!>      02.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE wfi_retain(wf_history)
      TYPE(qs_wf_history_type), POINTER                  :: wf_history

      CPASSERT(ASSOCIATED(wf_history))
      wf_history%ref_count = wf_history%ref_count + 1

   END SUBROUTINE wfi_retain

! **************************************************************************************************
!> \brief releases a wf_history of a wavefunction
!>      (see doc/ReferenceCounting.html)
!> \param wf_history the wf_history to release
!> \par History
!>      02.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE wfi_release(wf_history)
      TYPE(qs_wf_history_type), POINTER                  :: wf_history

      INTEGER                                            :: i

      IF (ASSOCIATED(wf_history)) THEN
         CPASSERT(wf_history%ref_count > 0)
         wf_history%ref_count = wf_history%ref_count - 1
         IF (wf_history%ref_count == 0) THEN
            IF (ASSOCIATED(wf_history%past_states)) THEN
               DO i = 1, SIZE(wf_history%past_states)
                  IF (ASSOCIATED(wf_history%past_states(i)%snapshot)) THEN
                     CALL wfs_release(wf_history%past_states(i)%snapshot)
                     DEALLOCATE (wf_history%past_states(i)%snapshot)
                  END IF
               END DO
               DEALLOCATE (wf_history%past_states)
            END IF
            DEALLOCATE (wf_history)
         END IF
      END IF
      NULLIFY (wf_history)
   END SUBROUTINE wfi_release

! **************************************************************************************************
!> \brief returns a snapshot, the first being the latest snapshot
!> \param wf_history the plage where to get the snapshot
!> \param wf_index the index of the snapshot you want
!> \return ...
!> \par History
!>      12.2002 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   FUNCTION wfi_get_snapshot(wf_history, wf_index) RESULT(res)
      TYPE(qs_wf_history_type), POINTER                  :: wf_history
      INTEGER, INTENT(in)                                :: wf_index
      TYPE(qs_wf_snapshot_type), POINTER                 :: res

      NULLIFY (res)

      CPASSERT(ASSOCIATED(wf_history))
      CPASSERT(ASSOCIATED(wf_history%past_states))
      IF (wf_index > wf_history%memory_depth .OR. wf_index > wf_history%snapshot_count) THEN
         CPABORT("")
      END IF
      res => wf_history%past_states( &
             MODULO(wf_history%snapshot_count + 1 - wf_index, &
                    wf_history%memory_depth) + 1)%snapshot
   END FUNCTION wfi_get_snapshot

END MODULE qs_wf_history_types
