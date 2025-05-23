!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief
!> \par History
!> \author  MI 07.2009
! **************************************************************************************************
MODULE gle_system_types
   USE bibliography,                    ONLY: Ceriotti2009,&
                                              Ceriotti2009b,&
                                              cite_reference
   USE extended_system_types,           ONLY: create_map_info_type,&
                                              map_info_type,&
                                              release_map_info_type
   USE input_section_types,             ONLY: section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE parallel_rng_types,              ONLY: GAUSSIAN,&
                                              next_rng_seed,&
                                              rng_stream_type
   USE string_utilities,                ONLY: compress
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: gle_dealloc, &
             gle_init, gle_thermo_create, &
             gle_type

!
   TYPE gle_thermo_type
      INTEGER                                 :: degrees_of_freedom = -1
      REAL(KIND=dp)                           :: nkt = 0.0_dp, kin_energy = 0.0_dp, thermostat_energy = 0.0_dp
      REAL(KIND=dp), DIMENSION(:), POINTER    :: s => NULL()
      TYPE(rng_stream_type)                   :: gaussian_rng_stream = rng_stream_type()
   END TYPE gle_thermo_type

! **************************************************************************************************
   TYPE gle_type
      INTEGER                                 :: ndim = -1
      INTEGER                                 :: glob_num_gle = -1, loc_num_gle = -1, region = -1
      INTEGER, DIMENSION(:), POINTER          :: mal => NULL()
      REAL(dp)                                :: temp = 0.0_dp, dt = 0.0_dp, dt_fact = 0.0_dp
      REAL(dp), POINTER                       :: gle_s(:, :) => NULL(), gle_t(:, :) => NULL()
      REAL(dp), POINTER                       :: a_mat(:, :) => NULL(), c_mat(:, :) => NULL()
      TYPE(gle_thermo_type), POINTER          :: nvt(:) => NULL()
      TYPE(map_info_type), POINTER            :: map_info => NULL()
   END TYPE gle_type

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'gle_system_types'

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param gle ...
!> \param dt ...
!> \param temp ...
!> \param section ...
!> \param
! **************************************************************************************************
   SUBROUTINE gle_init(gle, dt, temp, section)
      TYPE(gle_type), POINTER                            :: gle
      REAL(dp), INTENT(IN)                               :: dt, temp
      TYPE(section_vals_type), POINTER                   :: section

      INTEGER                                            :: i, ir, j, k, n_rep
      REAL(dp), DIMENSION(:), POINTER                    :: list
      REAL(KIND=dp)                                      :: a_scale

      NULLIFY (gle%nvt)
      NULLIFY (gle%gle_s)
      NULLIFY (gle%gle_t)
      NULLIFY (gle%map_info)
      gle%loc_num_gle = 0
      gle%glob_num_gle = 0
      gle%temp = temp
      gle%dt = dt*0.5_dp

      CALL cite_reference(Ceriotti2009)
      CALL cite_reference(Ceriotti2009b)
      CALL section_vals_val_get(section, "NDIM", i_val=gle%ndim)
      CALL section_vals_val_get(section, "A_SCALE", r_val=a_scale)

      ALLOCATE (gle%a_mat(gle%ndim, gle%ndim))
      ALLOCATE (gle%c_mat(gle%ndim, gle%ndim))
      ALLOCATE (gle%gle_s(gle%ndim, gle%ndim))
      ALLOCATE (gle%gle_t(gle%ndim, gle%ndim))

      CALL section_vals_val_get(section, "A_LIST", n_rep_val=n_rep)

      j = 1
      k = 1
      DO ir = 1, n_rep
         NULLIFY (list)
         CALL section_vals_val_get(section, "A_LIST", &
                                   i_rep_val=ir, r_vals=list)

         IF (ASSOCIATED(list)) THEN
            DO i = 1, SIZE(list)
               IF (j > gle%ndim) THEN
                  CPABORT("GLE: Too many elements in A_LIST")
               END IF
               gle%a_mat(j, k) = list(i)
               k = k + 1
               IF (k > gle%ndim) THEN
                  k = 1
                  j = j + 1
               END IF
            END DO
         END IF
      END DO ! ir
      IF (j < gle%ndim + 1) THEN
         CPABORT("GLE: Too few elements in A_LIST")
      END IF
      gle%a_mat = gle%a_mat*a_scale

      CALL section_vals_val_get(section, "C_LIST", n_rep_val=n_rep)
      IF (n_rep > 0) THEN
         j = 1
         k = 1
         DO ir = 1, n_rep
            NULLIFY (list)
            CALL section_vals_val_get(section, "C_LIST", &
                                      i_rep_val=ir, r_vals=list)

            IF (ASSOCIATED(list)) THEN
               DO i = 1, SIZE(list)
                  IF (j > gle%ndim) THEN
                     CPABORT("GLE: Too many elements in C_LIST")
                  END IF
                  gle%c_mat(j, k) = list(i)
                  k = k + 1
                  IF (k > gle%ndim) THEN
                     k = 1
                     j = j + 1
                  END IF
               END DO
            END IF
         END DO ! ir
         IF (j < gle%ndim + 1) THEN
            CPABORT("GLE: Too few elements in C_LIST")
         END IF
      ELSE
         gle%c_mat = 0.0_dp
         DO i = 1, gle%ndim
            gle%c_mat(i, i) = gle%temp
         END DO
      END IF
      CALL create_map_info_type(gle%map_info)
   END SUBROUTINE gle_init

! **************************************************************************************************
!> \brief ...
!> \param gle ...
!> \param mal_size ...
!> \param
! **************************************************************************************************
   SUBROUTINE gle_thermo_create(gle, mal_size)
      TYPE(gle_type), POINTER                            :: gle
      INTEGER, INTENT(IN)                                :: mal_size

      CHARACTER(LEN=40)                                  :: name
      INTEGER                                            :: i, ithermo, my_index
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: seed
      REAL(KIND=dp), DIMENSION(3, 2)                     :: initial_seed, my_seed

      CPASSERT(ASSOCIATED(gle))
      CPASSERT(.NOT. ASSOCIATED(gle%nvt))

      ALLOCATE (gle%nvt(gle%loc_num_gle))
      DO i = 1, gle%loc_num_gle
         NULLIFY (gle%nvt(i)%s)
         ALLOCATE (gle%nvt(i)%s(gle%ndim))
         gle%nvt(i)%kin_energy = 0.0_dp
         gle%nvt(i)%thermostat_energy = 0.0_dp
      END DO

      ALLOCATE (gle%mal(mal_size))
      gle%mal(:) = 0

      ! Initialize the gaussian stream random number
      initial_seed = next_rng_seed()
      ALLOCATE (seed(3, 2, gle%glob_num_gle))

      seed(:, :, 1) = initial_seed
      DO ithermo = 2, gle%glob_num_gle
         seed(:, :, ithermo) = next_rng_seed(seed(:, :, ithermo - 1))
      END DO

      ! Update initial seed
      initial_seed = next_rng_seed(seed(:, :, gle%glob_num_gle))
      DO ithermo = 1, gle%loc_num_gle
         my_index = gle%map_info%index(ithermo)
         my_seed = seed(:, :, my_index)
         WRITE (UNIT=name, FMT="(A,I8)") "Wiener process for Thermostat #", my_index
         CALL compress(name)
         gle%nvt(ithermo)%gaussian_rng_stream = rng_stream_type( &
                                                name=name, distribution_type=GAUSSIAN, extended_precision=.TRUE., seed=my_seed)
      END DO

      DEALLOCATE (seed)

   END SUBROUTINE gle_thermo_create

! **************************************************************************************************
!> \brief Deallocate type for GLE thermostat
!> \param gle ...
! **************************************************************************************************
   SUBROUTINE gle_dealloc(gle)
      TYPE(gle_type), POINTER                            :: gle

      INTEGER                                            :: i

      IF (ASSOCIATED(gle)) THEN
         IF (ASSOCIATED(gle%a_mat)) THEN
            DEALLOCATE (gle%a_mat)
         END IF
         IF (ASSOCIATED(gle%c_mat)) THEN
            DEALLOCATE (gle%c_mat)
         END IF
         IF (ASSOCIATED(gle%gle_t)) THEN
            DEALLOCATE (gle%gle_t)
         END IF
         IF (ASSOCIATED(gle%gle_s)) THEN
            DEALLOCATE (gle%gle_s)
         END IF
         IF (ASSOCIATED(gle%nvt)) THEN
            DO i = 1, SIZE(gle%nvt)
               DEALLOCATE (gle%nvt(i)%s)
            END DO
            DEALLOCATE (gle%nvt)
         END IF
         IF (ASSOCIATED(gle%mal)) THEN
            DEALLOCATE (gle%mal)
         END IF

         CALL release_map_info_type(gle%map_info)
         DEALLOCATE (gle)
      END IF

   END SUBROUTINE gle_dealloc

END MODULE gle_system_types
