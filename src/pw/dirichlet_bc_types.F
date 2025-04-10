!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief  Dirichlet boundary condition data types
!> \par History
!>       08.2014 created [Hossein Bani-Hashemian]
!>       10.2015 completely revised [Hossein Bani-Hashemian]
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
MODULE dirichlet_bc_types

   USE kinds,                           ONLY: dp
   USE pw_pool_types,                   ONLY: pw_pool_type
   USE pw_types,                        ONLY: pw_r3d_rs_type
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dirichlet_bc_types'

! main types
   TYPE :: dirichlet_bc_parameters
      LOGICAL                                  :: verbose_output = .FALSE.
      LOGICAL                                  :: do_dbc_cube = .FALSE.
      REAL(KIND=dp)                            :: time = 0.0_dp

      INTEGER                                  :: n_aa_planar = 0
      INTEGER, DIMENSION(:, :), POINTER         :: aa_planar_nprtn => NULL()
      INTEGER, DIMENSION(:), POINTER           :: aa_planar_pplane => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_planar_xxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_planar_yxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_planar_zxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_vD => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_osc_frac => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_frequency => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_phase => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_sigma => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_planar_thickness => NULL()
      LOGICAL, DIMENSION(:), POINTER           :: aa_planar_is_periodic => NULL()

      INTEGER                                  :: n_planar = 0
      INTEGER, DIMENSION(:, :), POINTER         :: planar_nprtn => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: planar_Avtx => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: planar_Bvtx => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: planar_Cvtx => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: planar_Dvtx => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_vD => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_osc_frac => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_frequency => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_phase => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_sigma => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: planar_thickness => NULL()
      LOGICAL, DIMENSION(:), POINTER           :: planar_is_periodic => NULL()

      INTEGER                                  :: n_aa_cylindrical = 0
      INTEGER, DIMENSION(:, :), POINTER         :: aa_cylindrical_nprtn => NULL()
      INTEGER, DIMENSION(:), POINTER           :: aa_cylindrical_paxis => NULL()
      INTEGER, DIMENSION(:), POINTER           :: aa_cylindrical_nsides => NULL()
      INTEGER, DIMENSION(:), POINTER           :: aa_cylindrical_apxtyp => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_cylindrical_xtnt => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_cylindrical_bctr => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_brad => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_vD => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_osc_frac => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_frequency => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_phase => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_sigma => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_thickness => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cylindrical_sgap => NULL()
      LOGICAL, DIMENSION(:), POINTER           :: aa_cylindrical_is_periodic => NULL()

      INTEGER                                  :: n_aa_cuboidal = 0
      INTEGER, DIMENSION(:, :), POINTER         :: aa_cuboidal_nprtn => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_cuboidal_xxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_cuboidal_yxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER   :: aa_cuboidal_zxtnt => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cuboidal_vD => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cuboidal_osc_frac => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cuboidal_frequency => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cuboidal_phase => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER     :: aa_cuboidal_sigma => NULL()
      LOGICAL, DIMENSION(:), POINTER           :: aa_cuboidal_is_periodic => NULL()
   END TYPE dirichlet_bc_parameters

   TYPE :: dirichlet_bc_type
      REAL(dp)                          :: v_D = 0.0_dp
      REAL(dp)                          :: osc_frac = 0.0_dp
      REAL(dp)                          :: frequency = 0.0_dp
      REAL(dp)                          :: phase = 0.0_dp
      INTEGER                           :: dbc_id = 0
      INTEGER                           :: dbc_geom = 0
      REAL(dp), DIMENSION(3, 8)          :: vertices = 0
      TYPE(tile_p_type), &
         DIMENSION(:), POINTER           :: tiles => NULL()
      INTEGER                           :: n_tiles = 0
      REAL(dp)                          :: smoothing_width = 0.0_dp
   END TYPE dirichlet_bc_type

   TYPE :: dirichlet_bc_p_type
      TYPE(dirichlet_bc_type), POINTER  :: dirichlet_bc => NULL()
   END TYPE dirichlet_bc_p_type

   TYPE :: tile_type
      INTEGER                           :: tile_id = 0
      REAL(dp), DIMENSION(3, 8)          :: vertices = 0
      TYPE(pw_r3d_rs_type), POINTER            :: tile_pw => NULL()
      REAL(dp)                          :: volume = 0.0_dp
   END TYPE tile_type

   TYPE :: tile_p_type
      TYPE(tile_type), POINTER          :: tile => NULL()
   END TYPE tile_p_type

! publicly accessible entities
   PUBLIC dirichlet_bc_type, dirichlet_bc_p_type, tile_type, tile_p_type
   PUBLIC dirichlet_bc_parameters

   PUBLIC dbc_release, &
      dbc_tile_release, &
      dbc_parameters_dealloc

! parameters
   INTEGER, PARAMETER, PUBLIC           :: AA_PLANAR = 10, &
                                           PLANAR = 11, &
                                           CYLINDRICAL = 20, &
                                           AA_CUBOIDAL = 30

   INTEGER, PARAMETER, PUBLIC           :: CIRCUMSCRIBED = 1, &
                                           INSCRIBED = 2

   INTEGER, PARAMETER, PUBLIC           :: xy_plane = 110, &
                                           xz_plane = 101, &
                                           yz_plane = 011

   INTEGER, PARAMETER, PUBLIC           :: x_axis = 100, &
                                           y_axis = 010, &
                                           z_axis = 001
CONTAINS

! **************************************************************************************************
!> \brief   releases the defined Dirichlet boundary region
!> \param contacts the DBC region to be released
!> \param do_dbc_cube ...
!> \param pw_pool pool of the plane wave grid
!> \par History
!>       08.2014 created [Hossein Bani-Hashemian]
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
   SUBROUTINE dbc_release(contacts, do_dbc_cube, pw_pool)

      TYPE(dirichlet_bc_p_type), ALLOCATABLE, &
         DIMENSION(:), INTENT(INOUT)                     :: contacts
      LOGICAL, INTENT(IN)                                :: do_dbc_cube
      TYPE(pw_pool_type), INTENT(IN), OPTIONAL, POINTER  :: pw_pool

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'dbc_release'

      INTEGER                                            :: handle, i, n_contacts

      CALL timeset(routineN, handle)

      IF (ALLOCATED(contacts)) THEN
         n_contacts = SIZE(contacts)
         IF (do_dbc_cube) THEN
            DO i = 1, n_contacts
               CALL dbc_tile_release(contacts(i)%dirichlet_bc, pw_pool)
               DEALLOCATE (contacts(i)%dirichlet_bc)
            END DO
         ELSE
            DO i = 1, n_contacts
               DEALLOCATE (contacts(i)%dirichlet_bc)
            END DO
         END IF
         DEALLOCATE (contacts)
      END IF

      CALL timestop(handle)

   END SUBROUTINE dbc_release

! **************************************************************************************************
!> \brief   releases tiles
!> \param dbc ...
!> \param pw_pool pool of the plane wave grid
!> \par History
!>       11.2015 created [Hossein Bani-Hashemian]
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
   SUBROUTINE dbc_tile_release(dbc, pw_pool)

      TYPE(dirichlet_bc_type), INTENT(INOUT), POINTER    :: dbc
      TYPE(pw_pool_type), INTENT(IN), OPTIONAL, POINTER  :: pw_pool

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'dbc_tile_release'

      INTEGER                                            :: handle, k, n_tiles

      CALL timeset(routineN, handle)

      n_tiles = dbc%n_tiles
      IF (PRESENT(pw_pool)) THEN
         DO k = 1, n_tiles
            CALL pw_pool%give_back_pw(dbc%tiles(k)%tile%tile_pw)
            DEALLOCATE (dbc%tiles(k)%tile%tile_pw)
            DEALLOCATE (dbc%tiles(k)%tile)
         END DO
         DEALLOCATE (dbc%tiles)
      ELSE
         DO k = 1, n_tiles
            CALL dbc%tiles(k)%tile%tile_pw%release()
            DEALLOCATE (dbc%tiles(k)%tile%tile_pw)
            DEALLOCATE (dbc%tiles(k)%tile)
         END DO
         DEALLOCATE (dbc%tiles)
      END IF

      CALL timestop(handle)

   END SUBROUTINE dbc_tile_release

! **************************************************************************************************
!> \brief   deallocates dirichlet_bc_parameters type
!> \param dbc_params dbc parameters
!> \par History
!>       08.2014 created [Hossein Bani-Hashemian]
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
   SUBROUTINE dbc_parameters_dealloc(dbc_params)

      TYPE(dirichlet_bc_parameters), INTENT(INOUT)       :: dbc_params

      IF (ASSOCIATED(dbc_params%aa_planar_nprtn)) DEALLOCATE (dbc_params%aa_planar_nprtn)
      IF (ASSOCIATED(dbc_params%aa_planar_pplane)) DEALLOCATE (dbc_params%aa_planar_pplane)
      IF (ASSOCIATED(dbc_params%aa_planar_xxtnt)) DEALLOCATE (dbc_params%aa_planar_xxtnt)
      IF (ASSOCIATED(dbc_params%aa_planar_yxtnt)) DEALLOCATE (dbc_params%aa_planar_yxtnt)
      IF (ASSOCIATED(dbc_params%aa_planar_zxtnt)) DEALLOCATE (dbc_params%aa_planar_zxtnt)
      IF (ASSOCIATED(dbc_params%aa_planar_vD)) DEALLOCATE (dbc_params%aa_planar_vD)
      IF (ASSOCIATED(dbc_params%aa_planar_frequency)) DEALLOCATE (dbc_params%aa_planar_frequency)
      IF (ASSOCIATED(dbc_params%aa_planar_osc_frac)) DEALLOCATE (dbc_params%aa_planar_osc_frac)
      IF (ASSOCIATED(dbc_params%aa_planar_phase)) DEALLOCATE (dbc_params%aa_planar_phase)
      IF (ASSOCIATED(dbc_params%aa_planar_sigma)) DEALLOCATE (dbc_params%aa_planar_sigma)
      IF (ASSOCIATED(dbc_params%aa_planar_thickness)) DEALLOCATE (dbc_params%aa_planar_thickness)
      IF (ASSOCIATED(dbc_params%aa_planar_is_periodic)) DEALLOCATE (dbc_params%aa_planar_is_periodic)

      IF (ASSOCIATED(dbc_params%planar_nprtn)) DEALLOCATE (dbc_params%planar_nprtn)
      IF (ASSOCIATED(dbc_params%planar_Avtx)) DEALLOCATE (dbc_params%planar_Avtx)
      IF (ASSOCIATED(dbc_params%planar_Bvtx)) DEALLOCATE (dbc_params%planar_Bvtx)
      IF (ASSOCIATED(dbc_params%planar_Cvtx)) DEALLOCATE (dbc_params%planar_Cvtx)
      IF (ASSOCIATED(dbc_params%planar_Dvtx)) DEALLOCATE (dbc_params%planar_Dvtx)
      IF (ASSOCIATED(dbc_params%planar_vD)) DEALLOCATE (dbc_params%planar_vD)
      IF (ASSOCIATED(dbc_params%planar_frequency)) DEALLOCATE (dbc_params%planar_frequency)
      IF (ASSOCIATED(dbc_params%planar_osc_frac)) DEALLOCATE (dbc_params%planar_osc_frac)
      IF (ASSOCIATED(dbc_params%planar_phase)) DEALLOCATE (dbc_params%planar_phase)
      IF (ASSOCIATED(dbc_params%planar_sigma)) DEALLOCATE (dbc_params%planar_sigma)
      IF (ASSOCIATED(dbc_params%planar_thickness)) DEALLOCATE (dbc_params%planar_thickness)
      IF (ASSOCIATED(dbc_params%planar_is_periodic)) DEALLOCATE (dbc_params%planar_is_periodic)

      IF (ASSOCIATED(dbc_params%aa_cylindrical_paxis)) DEALLOCATE (dbc_params%aa_cylindrical_paxis)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_nprtn)) DEALLOCATE (dbc_params%aa_cylindrical_nprtn)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_nsides)) DEALLOCATE (dbc_params%aa_cylindrical_nsides)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_apxtyp)) DEALLOCATE (dbc_params%aa_cylindrical_apxtyp)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_xtnt)) DEALLOCATE (dbc_params%aa_cylindrical_xtnt)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_bctr)) DEALLOCATE (dbc_params%aa_cylindrical_bctr)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_brad)) DEALLOCATE (dbc_params%aa_cylindrical_brad)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_vD)) DEALLOCATE (dbc_params%aa_cylindrical_vD)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_frequency)) DEALLOCATE (dbc_params%aa_cylindrical_frequency)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_osc_frac)) DEALLOCATE (dbc_params%aa_cylindrical_osc_frac)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_phase)) DEALLOCATE (dbc_params%aa_cylindrical_phase)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_sigma)) DEALLOCATE (dbc_params%aa_cylindrical_sigma)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_thickness)) DEALLOCATE (dbc_params%aa_cylindrical_thickness)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_sgap)) DEALLOCATE (dbc_params%aa_cylindrical_sgap)
      IF (ASSOCIATED(dbc_params%aa_cylindrical_is_periodic)) DEALLOCATE (dbc_params%aa_cylindrical_is_periodic)

      IF (ASSOCIATED(dbc_params%aa_cuboidal_nprtn)) DEALLOCATE (dbc_params%aa_cuboidal_nprtn)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_xxtnt)) DEALLOCATE (dbc_params%aa_cuboidal_xxtnt)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_yxtnt)) DEALLOCATE (dbc_params%aa_cuboidal_yxtnt)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_zxtnt)) DEALLOCATE (dbc_params%aa_cuboidal_zxtnt)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_vD)) DEALLOCATE (dbc_params%aa_cuboidal_vD)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_frequency)) DEALLOCATE (dbc_params%aa_cuboidal_frequency)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_osc_frac)) DEALLOCATE (dbc_params%aa_cuboidal_osc_frac)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_phase)) DEALLOCATE (dbc_params%aa_cuboidal_phase)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_sigma)) DEALLOCATE (dbc_params%aa_cuboidal_sigma)
      IF (ASSOCIATED(dbc_params%aa_cuboidal_is_periodic)) DEALLOCATE (dbc_params%aa_cuboidal_is_periodic)

   END SUBROUTINE dbc_parameters_dealloc

END MODULE dirichlet_bc_types
