!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief basic functionality for using ot in the scf routines.
!> \par History
!>      01.2003 : Joost VandeVondele : adapted for LSD
!> \author Joost VandeVondele (25.08.2002)
! **************************************************************************************************
MODULE qs_ot_scf
   USE cp_array_utils,                  ONLY: cp_1d_r_p_type
   USE cp_dbcsr_api,                    ONLY: &
        dbcsr_copy, dbcsr_get_info, dbcsr_init_p, dbcsr_multiply, dbcsr_p_type, dbcsr_release, &
        dbcsr_set, dbcsr_type, dbcsr_type_no_symmetry
   USE cp_dbcsr_contrib,                ONLY: dbcsr_dot,&
                                              dbcsr_get_diag,&
                                              dbcsr_scale_by_vector,&
                                              dbcsr_set_diag
   USE cp_dbcsr_operations,             ONLY: copy_fm_to_dbcsr,&
                                              cp_dbcsr_m_by_n_from_row_template
   USE cp_fm_types,                     ONLY: cp_fm_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE qs_mo_occupation,                ONLY: set_mo_occupation
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_restrict,&
                                              mo_set_type
   USE qs_ot,                           ONLY: qs_ot_get_orbitals,&
                                              qs_ot_get_orbitals_ref,&
                                              qs_ot_get_p
   USE qs_ot_minimizer,                 ONLY: ot_mini
   USE qs_ot_types,                     ONLY: ot_readwrite_input,&
                                              qs_ot_allocate,&
                                              qs_ot_destroy,&
                                              qs_ot_init,&
                                              qs_ot_settings_init,&
                                              qs_ot_type
   USE scf_control_types,               ONLY: smear_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_ot_scf'
   ! *** Public subroutines ***

   PUBLIC :: ot_scf_init
   PUBLIC :: ot_scf_mini
   PUBLIC :: ot_scf_destroy
   PUBLIC :: ot_scf_read_input

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_ot_env ...
!> \param scf_section ...
! **************************************************************************************************
   SUBROUTINE ot_scf_read_input(qs_ot_env, scf_section)
      TYPE(qs_ot_type), DIMENSION(:), POINTER            :: qs_ot_env
      TYPE(section_vals_type), POINTER                   :: scf_section

      CHARACTER(len=*), PARAMETER                        :: routineN = 'ot_scf_read_input'

      INTEGER                                            :: handle, ispin, nspin, output_unit
      LOGICAL                                            :: explicit
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(section_vals_type), POINTER                   :: ot_section

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()
      output_unit = cp_print_key_unit_nr(logger, scf_section, "PRINT%PROGRAM_RUN_INFO", &
                                         extension=".log")

      ! decide default settings
      CALL qs_ot_settings_init(qs_ot_env(1)%settings)

      ! use ot input new style
      ot_section => section_vals_get_subs_vals(scf_section, "OT")
      CALL section_vals_get(ot_section, explicit=explicit)

      CALL ot_readwrite_input(qs_ot_env(1)%settings, ot_section, output_unit)

      CALL cp_print_key_finished_output(output_unit, logger, scf_section, &
                                        "PRINT%PROGRAM_RUN_INFO")

      ! copy the ot settings type so it is identical
      nspin = SIZE(qs_ot_env)
      DO ispin = 2, nspin
         qs_ot_env(ispin)%settings = qs_ot_env(1)%settings
      END DO

      CALL timestop(handle)

   END SUBROUTINE ot_scf_read_input
! **************************************************************************************************
   !
   ! performs the actual minimisation, needs only limited info
   ! updated for restricted calculations
   ! matrix_dedc is the derivative of the energy with respect to the orbitals (except for a factor 2*fi)
   ! a null pointer for matrix_s implies that matrix_s is the unit matrix
   !
   !
! **************************************************************************************************
!> \brief ...
!> \param mo_array ...
!> \param matrix_dedc ...
!> \param smear ...
!> \param matrix_s ...
!> \param energy ...
!> \param energy_only ...
!> \param delta ...
!> \param qs_ot_env ...
! **************************************************************************************************
   SUBROUTINE ot_scf_mini(mo_array, matrix_dedc, smear, matrix_s, energy, &
                          energy_only, delta, qs_ot_env)

      TYPE(mo_set_type), DIMENSION(:), INTENT(INOUT)     :: mo_array
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_dedc
      TYPE(smear_type), POINTER                          :: smear
      TYPE(dbcsr_type), POINTER                          :: matrix_s
      REAL(KIND=dp)                                      :: energy
      LOGICAL, INTENT(INOUT)                             :: energy_only
      REAL(KIND=dp)                                      :: delta
      TYPE(qs_ot_type), DIMENSION(:), POINTER            :: qs_ot_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'ot_scf_mini'

      INTEGER                                            :: handle, ispin, k, n, nspin
      REAL(KIND=dp)                                      :: ener_nondiag, trace
      TYPE(cp_1d_r_p_type), ALLOCATABLE, DIMENSION(:)    :: expectation_values, occupation_numbers, &
                                                            scaling_factor
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_dedc_scaled
      TYPE(dbcsr_type), POINTER                          :: mo_coeff

      CALL timeset(routineN, handle)

      NULLIFY (logger)
      logger => cp_get_default_logger()

      nspin = SIZE(mo_array)

      ALLOCATE (occupation_numbers(nspin))
      ALLOCATE (scaling_factor(nspin))

      IF (qs_ot_env(1)%settings%do_ener) THEN
         ALLOCATE (expectation_values(nspin))
      END IF

      DO ispin = 1, nspin
         CALL get_mo_set(mo_set=mo_array(ispin), occupation_numbers=occupation_numbers(ispin)%array)
         ALLOCATE (scaling_factor(ispin)%array(SIZE(occupation_numbers(ispin)%array)))
         scaling_factor(ispin)%array = 2.0_dp*occupation_numbers(ispin)%array
         IF (qs_ot_env(1)%settings%do_ener) THEN
            ALLOCATE (expectation_values(ispin)%array(SIZE(occupation_numbers(ispin)%array)))
         END IF
      END DO

      ! optimizing orbital energies somehow implies non-equivalent orbitals
      IF (qs_ot_env(1)%settings%do_ener) THEN
         CPASSERT(qs_ot_env(1)%settings%do_rotation)
      END IF
      ! add_nondiag_energy requires do_ener
      IF (qs_ot_env(1)%settings%add_nondiag_energy) THEN
         CPASSERT(qs_ot_env(1)%settings%do_ener)
      END IF

      ! get a rotational force
      IF (.NOT. energy_only) THEN
         IF (qs_ot_env(1)%settings%do_rotation) THEN
            DO ispin = 1, SIZE(qs_ot_env)
               CALL get_mo_set(mo_set=mo_array(ispin), mo_coeff_b=mo_coeff)
               CALL dbcsr_get_info(mo_coeff, nfullrows_total=n, nfullcols_total=k)
               CALL dbcsr_multiply('T', 'N', 1.0_dp, mo_coeff, matrix_dedc(ispin)%matrix, &
                                   0.0_dp, qs_ot_env(ispin)%rot_mat_chc)
               CALL dbcsr_copy(qs_ot_env(ispin)%matrix_buf1, qs_ot_env(ispin)%rot_mat_chc)

               CALL dbcsr_scale_by_vector(qs_ot_env(ispin)%matrix_buf1, alpha=scaling_factor(ispin)%array, side='right')
               ! create the derivative of the energy wrt to rot_mat_u
               CALL dbcsr_multiply('N', 'N', 1.0_dp, qs_ot_env(ispin)%rot_mat_u, qs_ot_env(ispin)%matrix_buf1, &
                                   0.0_dp, qs_ot_env(ispin)%rot_mat_dedu)
            END DO

            ! here we construct the derivative of the free energy with respect to the evals
            ! (note that this requires the diagonal elements of chc)
            ! the mo occupations should in principle remain unaltered
            IF (qs_ot_env(1)%settings%do_ener) THEN
               DO ispin = 1, SIZE(mo_array)
                  CALL dbcsr_get_diag(qs_ot_env(ispin)%rot_mat_chc, expectation_values(ispin)%array)
                  qs_ot_env(ispin)%ener_gx = expectation_values(ispin)%array
                  CALL set_mo_occupation(mo_set=mo_array(ispin), &
                                         smear=smear, eval_deriv=qs_ot_env(ispin)%ener_gx)
               END DO
            END IF

            ! chc only needs to be stored in u independent form if we require add_nondiag_energy,
            ! which will use it in non-selfconsistent form for e.g. the linesearch
            ! transform C^T H C -> U C^T H C U ^ T
            IF (qs_ot_env(1)%settings%add_nondiag_energy) THEN
               DO ispin = 1, SIZE(qs_ot_env)
                  CALL dbcsr_get_info(qs_ot_env(ispin)%rot_mat_u, nfullcols_total=k)
                  CALL dbcsr_multiply('N', 'N', 1.0_dp, qs_ot_env(ispin)%rot_mat_u, qs_ot_env(ispin)%rot_mat_chc, &
                                      0.0_dp, qs_ot_env(ispin)%matrix_buf1)
                  CALL dbcsr_multiply('N', 'T', 1.0_dp, qs_ot_env(ispin)%matrix_buf1, qs_ot_env(ispin)%rot_mat_u, &
                                      0.0_dp, qs_ot_env(ispin)%rot_mat_chc)
               END DO
            END IF
         END IF
      END IF

      ! evaluate non-diagonal energy contribution
      ener_nondiag = 0.0_dp
      IF (qs_ot_env(1)%settings%add_nondiag_energy) THEN
         DO ispin = 1, SIZE(qs_ot_env)
            ! transform \tilde H to the current basis of C (assuming non-selfconsistent H)
            CALL dbcsr_get_info(qs_ot_env(ispin)%rot_mat_u, nfullcols_total=k)
            CALL dbcsr_multiply('T', 'N', 1.0_dp, qs_ot_env(ispin)%rot_mat_u, qs_ot_env(ispin)%rot_mat_chc, &
                                0.0_dp, qs_ot_env(ispin)%matrix_buf1)
            CALL dbcsr_multiply('N', 'N', 1.0_dp, qs_ot_env(ispin)%matrix_buf1, qs_ot_env(ispin)%rot_mat_u, &
                                0.0_dp, qs_ot_env(ispin)%matrix_buf2)

            ! subtract the current ener_x from the diagonal
            CALL dbcsr_get_diag(qs_ot_env(ispin)%matrix_buf2, expectation_values(ispin)%array)
            expectation_values(ispin)%array = expectation_values(ispin)%array - qs_ot_env(ispin)%ener_x
            CALL dbcsr_set_diag(qs_ot_env(ispin)%matrix_buf2, expectation_values(ispin)%array)

            ! get nondiag energy trace (D^T D)
            CALL dbcsr_dot(qs_ot_env(ispin)%matrix_buf2, qs_ot_env(ispin)%matrix_buf2, trace)
            ener_nondiag = ener_nondiag + 0.5_dp*qs_ot_env(1)%settings%nondiag_energy_strength*trace

            ! get gradient (again ignoring dependencies of H)
            IF (.NOT. energy_only) THEN
               ! first for the ener_x (-2*(diag(C^T H C)-ener_x))
               qs_ot_env(ispin)%ener_gx = qs_ot_env(ispin)%ener_gx - &
                                          qs_ot_env(1)%settings%nondiag_energy_strength*expectation_values(ispin)%array

               ! next for the rot_mat_u derivative (2 * k * \tilde H U D)
               CALL dbcsr_multiply('N', 'N', 1.0_dp, qs_ot_env(ispin)%rot_mat_chc, qs_ot_env(ispin)%rot_mat_u, &
                                   0.0_dp, qs_ot_env(ispin)%matrix_buf1)
               CALL dbcsr_multiply('N', 'N', 2.0_dp*qs_ot_env(1)%settings%nondiag_energy_strength, &
                                   qs_ot_env(ispin)%matrix_buf1, qs_ot_env(ispin)%matrix_buf2, &
                                   1.0_dp, qs_ot_env(ispin)%rot_mat_dedu)
            END IF
         END DO
      END IF

      ! this is kind of a hack so far (costly memory wise), we locally recreate the scaled matrix_hc, and
      ! use it in the following, eventually, as occupations numbers get more integrated, it should become possible
      ! to remove this.
      ALLOCATE (matrix_dedc_scaled(SIZE(matrix_dedc)))
      DO ispin = 1, SIZE(matrix_dedc)
         ALLOCATE (matrix_dedc_scaled(ispin)%matrix)
         CALL dbcsr_copy(matrix_dedc_scaled(ispin)%matrix, matrix_dedc(ispin)%matrix)

         ! as a preconditioner, one might want to scale only with a constant, not with f(i)
         ! for the convergence criterion, maybe take it back out
         IF (qs_ot_env(1)%settings%occupation_preconditioner) THEN
            scaling_factor(ispin)%array = 2.0_dp
         END IF
         CALL dbcsr_scale_by_vector(matrix_dedc_scaled(ispin)%matrix, alpha=scaling_factor(ispin)%array, side='right')
      END DO

      ! notice we use qs_ot_env(1) for driving all output and the minimization in case of LSD
      qs_ot_env(1)%etotal = energy + ener_nondiag

      CALL ot_mini(qs_ot_env, matrix_dedc_scaled)

      delta = qs_ot_env(1)%delta
      energy_only = qs_ot_env(1)%energy_only

      ! generate the orbitals using the new matrix_x
      DO ispin = 1, SIZE(qs_ot_env)
         CALL get_mo_set(mo_set=mo_array(ispin), mo_coeff_b=mo_coeff)
         CALL dbcsr_get_info(mo_coeff, nfullrows_total=n, nfullcols_total=k)
         SELECT CASE (qs_ot_env(1)%settings%ot_algorithm)
         CASE ("TOD")
            IF (ASSOCIATED(matrix_s)) THEN
               CALL dbcsr_multiply('N', 'N', 1.0_dp, matrix_s, qs_ot_env(ispin)%matrix_x, &
                                   0.0_dp, qs_ot_env(ispin)%matrix_sx)
            ELSE
               CALL dbcsr_copy(qs_ot_env(ispin)%matrix_sx, qs_ot_env(ispin)%matrix_x)
            END IF
            CALL qs_ot_get_p(qs_ot_env(ispin)%matrix_x, qs_ot_env(ispin)%matrix_sx, qs_ot_env(ispin))
            CALL qs_ot_get_orbitals(mo_coeff, qs_ot_env(ispin)%matrix_x, qs_ot_env(ispin))
         CASE ("REF")
            CALL qs_ot_get_orbitals_ref(mo_coeff, matrix_s, qs_ot_env(ispin)%matrix_x, &
                                        qs_ot_env(ispin)%matrix_sx, qs_ot_env(ispin)%matrix_gx_old, &
                                        qs_ot_env(ispin)%matrix_dx, qs_ot_env(ispin), qs_ot_env(1))
         CASE DEFAULT
            CPABORT("Algorithm not yet implemented")
         END SELECT
      END DO

      IF (qs_ot_env(1)%restricted) THEN
         CALL mo_set_restrict(mo_array, convert_dbcsr=.TRUE.)
      END IF
      !
      ! obtain the new set of OT eigenvalues and set the occupations accordingly
      !
      IF (qs_ot_env(1)%settings%do_ener) THEN
         DO ispin = 1, SIZE(mo_array)
            mo_array(ispin)%eigenvalues = qs_ot_env(ispin)%ener_x
            CALL set_mo_occupation(mo_set=mo_array(ispin), &
                                   smear=smear)
         END DO
      END IF

      ! cleanup
      DO ispin = 1, SIZE(scaling_factor)
         DEALLOCATE (scaling_factor(ispin)%array)
      END DO
      DEALLOCATE (scaling_factor)
      IF (qs_ot_env(1)%settings%do_ener) THEN
         DO ispin = 1, SIZE(expectation_values)
            DEALLOCATE (expectation_values(ispin)%array)
         END DO
         DEALLOCATE (expectation_values)
      END IF
      DEALLOCATE (occupation_numbers)
      DO ispin = 1, SIZE(matrix_dedc_scaled)
         CALL dbcsr_release(matrix_dedc_scaled(ispin)%matrix)
         DEALLOCATE (matrix_dedc_scaled(ispin)%matrix)
      END DO
      DEALLOCATE (matrix_dedc_scaled)

      CALL timestop(handle)

   END SUBROUTINE ot_scf_mini
   !
   ! initialises qs_ot_env so that mo_coeff is the current point
   ! and that the mimizization can be started.
   !
! **************************************************************************************************
!> \brief ...
!> \param mo_array ...
!> \param matrix_s ...
!> \param qs_ot_env ...
!> \param matrix_ks ...
!> \param broyden_adaptive_sigma ...
! **************************************************************************************************
   SUBROUTINE ot_scf_init(mo_array, matrix_s, qs_ot_env, matrix_ks, broyden_adaptive_sigma)

      TYPE(mo_set_type), DIMENSION(:), INTENT(IN)        :: mo_array
      TYPE(dbcsr_type), POINTER                          :: matrix_s
      TYPE(qs_ot_type), DIMENSION(:), POINTER            :: qs_ot_env
      TYPE(dbcsr_type), POINTER                          :: matrix_ks
      REAL(KIND=dp)                                      :: broyden_adaptive_sigma

      CHARACTER(len=*), PARAMETER                        :: routineN = 'ot_scf_init'

      INTEGER                                            :: handle, ispin, k, n, nspin
      LOGICAL                                            :: is_equal
      TYPE(cp_fm_type), POINTER                          :: mo_coeff_fm
      TYPE(dbcsr_type), POINTER                          :: mo_coeff

      CALL timeset(routineN, handle)

      DO ispin = 1, SIZE(mo_array)
         IF (.NOT. ASSOCIATED(mo_array(ispin)%mo_coeff_b)) THEN
            CPABORT("Shouldn't get there")
            ! we do ot then copy fm to dbcsr
            ! allocate that somewhere else ! fm -> dbcsr
            CALL dbcsr_init_p(mo_array(ispin)%mo_coeff_b)
            CALL cp_dbcsr_m_by_n_from_row_template(mo_array(ispin)%mo_coeff_b, template=matrix_ks, &
                                                   n=mo_array(ispin)%nmo, &
                                                   sym=dbcsr_type_no_symmetry)
         END IF
      END DO

      ! *** set a history for broyden
      DO ispin = 1, SIZE(qs_ot_env)
         qs_ot_env(ispin)%broyden_adaptive_sigma = broyden_adaptive_sigma
      END DO

      ! **** SCP
      ! **** SCP
      ! adapted for work with the restricted keyword
      nspin = SIZE(qs_ot_env)

      DO ispin = 1, nspin

         NULLIFY (mo_coeff)
         CALL get_mo_set(mo_set=mo_array(ispin), mo_coeff_b=mo_coeff, mo_coeff=mo_coeff_fm)
         CALL copy_fm_to_dbcsr(mo_coeff_fm, mo_coeff) !fm -> dbcsr

         CALL dbcsr_get_info(mo_coeff, nfullrows_total=n, nfullcols_total=k)

         ! allocate
         CALL qs_ot_allocate(qs_ot_env(ispin), matrix_ks, mo_coeff_fm%matrix_struct)

         ! set c0,sc0
         CALL dbcsr_copy(qs_ot_env(ispin)%matrix_c0, mo_coeff)
         IF (ASSOCIATED(matrix_s)) THEN
            CALL dbcsr_multiply('N', 'N', 1.0_dp, matrix_s, qs_ot_env(ispin)%matrix_c0, &
                                0.0_dp, qs_ot_env(ispin)%matrix_sc0)
         ELSE
            CALL dbcsr_copy(qs_ot_env(ispin)%matrix_sc0, qs_ot_env(ispin)%matrix_c0)
         END IF

         ! init
         CALL qs_ot_init(qs_ot_env(ispin))

         ! set x
         CALL dbcsr_set(qs_ot_env(ispin)%matrix_x, 0.0_dp)
         CALL dbcsr_set(qs_ot_env(ispin)%matrix_sx, 0.0_dp)

         IF (qs_ot_env(ispin)%settings%do_rotation) THEN
            CALL dbcsr_set(qs_ot_env(ispin)%rot_mat_x, 0.0_dp)
         END IF

         IF (qs_ot_env(ispin)%settings%do_ener) THEN
            is_equal = SIZE(qs_ot_env(ispin)%ener_x) == SIZE(mo_array(ispin)%eigenvalues)
            CPASSERT(is_equal)
            qs_ot_env(ispin)%ener_x = mo_array(ispin)%eigenvalues
         END IF

         SELECT CASE (qs_ot_env(1)%settings%ot_algorithm)
         CASE ("TOD")
            ! get c
            CALL qs_ot_get_p(qs_ot_env(ispin)%matrix_x, qs_ot_env(ispin)%matrix_sx, qs_ot_env(ispin))
         CASE ("REF")
            CALL dbcsr_copy(qs_ot_env(ispin)%matrix_x, qs_ot_env(ispin)%matrix_c0)
            CALL dbcsr_copy(qs_ot_env(ispin)%matrix_sx, qs_ot_env(ispin)%matrix_sc0)
         CASE DEFAULT
            CPABORT("Algorithm not yet implemented")
         END SELECT

      END DO
      CALL timestop(handle)
   END SUBROUTINE ot_scf_init

! **************************************************************************************************
!> \brief ...
!> \param qs_ot_env ...
! **************************************************************************************************
   SUBROUTINE ot_scf_destroy(qs_ot_env)

      TYPE(qs_ot_type)                                   :: qs_ot_env

      CALL qs_ot_destroy(qs_ot_env)

   END SUBROUTINE ot_scf_destroy

END MODULE qs_ot_scf

