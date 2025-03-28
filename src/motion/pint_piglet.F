!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief  Methods to apply the piglet thermostat to PI runs.
!> \author Felix Uhl
!> \par History
!>      10.2014 created [Felix Uhl]
! **************************************************************************************************
MODULE pint_piglet
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_units,                        ONLY: cp_unit_from_cp2k,&
                                              cp_unit_to_cp2k
   USE gle_system_dynamics,             ONLY: gle_cholesky_stab,&
                                              gle_matrix_exp
   USE input_constants,                 ONLY: matrix_init_cholesky,&
                                              matrix_init_diagonal,&
                                              propagator_rpmd
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_path_length,&
                                              default_string_length,&
                                              dp
   USE message_passing,                 ONLY: mp_para_env_type
   USE parallel_rng_types,              ONLY: GAUSSIAN,&
                                              rng_record_length,&
                                              rng_stream_type,&
                                              rng_stream_type_from_record
   USE pint_io,                         ONLY: pint_write_line
   USE pint_types,                      ONLY: piglet_therm_type,&
                                              pint_env_type
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   PUBLIC :: pint_piglet_create, &
             pint_piglet_init, &
             pint_piglet_step, &
             pint_piglet_release, &
             pint_calc_piglet_energy

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'pint_piglet'

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!                                           !
!       _._ _..._ .-',     _.._   _         !
!      '-. `     '  /-._.-'    ',/ )        !
!         )         \            '.         !
!        / _    _    |             \        !
!       |  o    o    /              |       !
!       \   .-.                     ;       !
!        '-('' ).-'       ,'       ;        !
!           '-;           |      .'         !
!              \           \    /           !
!              | 7  .__  _.-\   \           !
!              | |  |  ``/  /`  /           !
!             /,_|  |   /,_/   /            !
!                /,_/      '`-'             !
!                                           !
!    (    (             (                   !
!    )\ ) )\ )  (       )\ )        *   )   !
!   (()/((()/(  )\ )   (()/(  (   ` )  /(   !
!    /(_))/(_))(()/(    /(_)) )\   ( )(_))  !
!   (_)) (_))   /(_))_ (_))  ((_) (_(_())   !
!   | _ \|_ _| (_)) __|| |   | __||_   _|   !
!   |  _/ | |    | (_ || |__ | _|   | |     !
!   |_|  |___|    \___||____||___|  |_|     !
!                                           !
!        Make Quantum Mechanics Hot         !
!                                           !
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

CONTAINS

! ***************************************************************************
!> \brief creates the data structure for a piglet thermostating in PI runs
!> \param piglet_therm ...
!> \param pint_env ...
!> \param section ...
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE pint_piglet_create(piglet_therm, pint_env, section)
      TYPE(piglet_therm_type), INTENT(OUT)               :: piglet_therm
      TYPE(pint_env_type), INTENT(IN)                    :: pint_env
      TYPE(section_vals_type), POINTER                   :: section

      INTEGER                                            :: ndim, p

      CALL section_vals_val_get(section, "NEXTRA_DOF", i_val=piglet_therm%nsp1)
      !add real degree of freedom to ns to reach nsp1
      piglet_therm%nsp1 = piglet_therm%nsp1 + 1
      p = pint_env%p
      piglet_therm%p = pint_env%p
      ndim = pint_env%ndim
      piglet_therm%ndim = pint_env%ndim
      NULLIFY (piglet_therm%a_mat)
      ALLOCATE (piglet_therm%a_mat(piglet_therm%nsp1, piglet_therm%nsp1, p))
      piglet_therm%a_mat(:, :, :) = 0.0_dp
      NULLIFY (piglet_therm%c_mat)
      ALLOCATE (piglet_therm%c_mat(piglet_therm%nsp1, piglet_therm%nsp1, p))
      piglet_therm%c_mat(:, :, :) = 0.0_dp
      NULLIFY (piglet_therm%gle_t)
      ALLOCATE (piglet_therm%gle_t(piglet_therm%nsp1, piglet_therm%nsp1, p))
      piglet_therm%gle_t(:, :, :) = 0.0_dp
      NULLIFY (piglet_therm%gle_s)
      ALLOCATE (piglet_therm%gle_s(piglet_therm%nsp1, piglet_therm%nsp1, p))
      piglet_therm%gle_s(:, :, :) = 0.0_dp
      NULLIFY (piglet_therm%smalls)
      ALLOCATE (piglet_therm%smalls(piglet_therm%nsp1, ndim*p))
      piglet_therm%smalls(:, :) = 0.0_dp
      NULLIFY (piglet_therm%temp1)
      ALLOCATE (piglet_therm%temp1(piglet_therm%nsp1, ndim))
      piglet_therm%temp1(:, :) = 0.0_dp
      NULLIFY (piglet_therm%temp2)
      ALLOCATE (piglet_therm%temp2(piglet_therm%nsp1, ndim))
      piglet_therm%temp2(:, :) = 0.0_dp
      NULLIFY (piglet_therm%sqrtmass)
      ALLOCATE (piglet_therm%sqrtmass(piglet_therm%p, piglet_therm%ndim))
      piglet_therm%sqrtmass(:, :) = 0.0_dp

   END SUBROUTINE pint_piglet_create

! ***************************************************************************
!> \brief initializes the data for a piglet run
!> \param piglet_therm ...
!> \param pint_env ...
!> \param section ...
!> \param dt ...
!> \param para_env ...
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE pint_piglet_init(piglet_therm, pint_env, section, dt, para_env)
      TYPE(piglet_therm_type), INTENT(INOUT)             :: piglet_therm
      TYPE(pint_env_type), INTENT(INOUT)                 :: pint_env
      TYPE(section_vals_type), POINTER                   :: section
      REAL(KIND=dp), INTENT(IN)                          :: dt
      TYPE(mp_para_env_type), POINTER                    :: para_env

      CHARACTER(len=20)                                  :: default_format, read_unit
      CHARACTER(len=default_path_length)                 :: matrices_file_name
      CHARACTER(len=default_string_length)               :: msg, temp_input
      CHARACTER(LEN=rng_record_length)                   :: rng_record
      INTEGER                                            :: cbrac, i, ibead, idim, imode, &
                                                            input_unit, isp, j, matrix_init, ns, &
                                                            obrac, p, read_err
      LOGICAL                                            :: explicit
      REAL(KIND=dp), DIMENSION(3, 2)                     :: initial_seed
      REAL(KIND=dp), DIMENSION(:), POINTER               :: smallstmp
      REAL(KIND=dp), &
         DIMENSION(piglet_therm%nsp1, piglet_therm%nsp1) :: Mtmp, tmpmatrix
      TYPE(section_vals_type), POINTER                   :: rng_section, smalls_section

      p = piglet_therm%p
      pint_env%e_piglet = 0.0_dp
      pint_env%piglet_therm%thermostat_energy = 0.0_dp
      CALL section_vals_val_get(section, "THERMOSTAT_ENERGY", r_val=piglet_therm%thermostat_energy)
      CALL section_vals_val_get(section, "SMATRIX_INIT", i_val=matrix_init)
      !Read the matices

      IF (pint_env%propagator%prop_kind /= propagator_rpmd) THEN
         CPABORT("PIGLET is designed to work with the RPMD propagator")
      END IF
      ! Select algorithm for S-matrix initialization
      IF (matrix_init == matrix_init_cholesky) THEN
         IF (para_env%is_source()) THEN
            CALL pint_write_line("PIGLET| Initalizing S-matrices using cholesky decomposition.")
         END IF
      ELSE IF (matrix_init == matrix_init_diagonal) THEN
         IF (para_env%is_source()) THEN
            CALL pint_write_line("PIGLET| Initalizing S-matrices using full diagonalization.")
         END IF
      ELSE
         CPWARN("No PIGLET init algorithm selected. Selecting cholesky decomposition")
         matrix_init = matrix_init_cholesky
      END IF

      IF (para_env%is_source()) THEN
         ! Read input matrices
         WRITE (default_format, '(A,I10,A)') "(A", default_string_length, ")"
         CALL section_vals_val_get(section, "MATRICES_FILE_NAME", &
                                   c_val=matrices_file_name)
         CALL pint_write_line("PIGLET| Reading PIGLET matrices from file: ")
         CALL pint_write_line("PIGLET|    "//TRIM(matrices_file_name))
         CALL open_file(file_name=TRIM(matrices_file_name), &
                        file_action="READ", file_status="OLD", unit_number=input_unit)
         read_err = 0
         msg = ""
         DO WHILE (read_err == 0)
            READ (input_unit, default_format, iostat=read_err) temp_input
            IF (read_err /= 0) EXIT
            !Parse comment section
            IF (INDEX(temp_input, "#") /= 0) THEN
               IF (INDEX(temp_input, "T=") /= 0) THEN
                  CALL check_temperature(line=temp_input, &
                                         propagator=pint_env%propagator%prop_kind, &
                                         targettemp=pint_env%kT*pint_env%propagator%temp_sim2phys)
               ELSE IF (INDEX(temp_input, "A MATRIX") /= 0) THEN
                  obrac = INDEX(temp_input, "(") + 1
                  cbrac = INDEX(temp_input, ")") - 1
                  read_unit = temp_input(obrac:cbrac)
                  DO imode = 1, p
                     READ (input_unit, default_format) temp_input
                     DO i = 1, piglet_therm%nsp1
                        READ (input_unit, *, iostat=read_err) &
                           (piglet_therm%a_mat(i, j, imode), j=1, piglet_therm%nsp1)
                        IF (read_err /= 0) THEN
                           WRITE (UNIT=msg, FMT=*) "Invalid PIGLET A-matrix Nr.", i - 1
                           CPABORT(msg)
                           EXIT
                        END IF
                     END DO
                  END DO
                  !convert to cp2k units
                  IF (read_err == 0) THEN
                     CALL a_mat_to_cp2k(piglet_therm%a_mat, p, &
                                        piglet_therm%nsp1, read_unit, msg)
                  END IF
               ELSE IF (INDEX(temp_input, "C MATRIX") /= 0) THEN
                  obrac = INDEX(temp_input, "(") + 1
                  cbrac = INDEX(temp_input, ")") - 1
                  read_unit = temp_input(obrac:cbrac)
                  DO imode = 1, p
                     READ (input_unit, default_format) temp_input
                     DO i = 1, piglet_therm%nsp1
                        READ (input_unit, *, iostat=read_err) &
                           (piglet_therm%c_mat(i, j, imode), j=1, piglet_therm%nsp1)
                        IF (read_err /= 0) THEN
                           WRITE (UNIT=msg, FMT=*) "Invalid PIGLET C-matrix Nr.", i - 1
                           CPABORT(msg)
                           EXIT
                        END IF
                     END DO
                  END DO
                  IF (read_err == 0) THEN
                     CALL c_mat_to_cp2k(piglet_therm%c_mat, p, &
                                        piglet_therm%nsp1, read_unit, msg)
                  END IF
               END IF
            END IF
         END DO
         CALL close_file(unit_number=input_unit)
      END IF
      ! communicate A and C matrix to other nodes
      CALL para_env%bcast(piglet_therm%a_mat, &
                          para_env%source)
      CALL para_env%bcast(piglet_therm%c_mat, &
                          para_env%source)

      !prepare Random number generator
      NULLIFY (rng_section)
      rng_section => section_vals_get_subs_vals(section, &
                                                subsection_name="RNG_INIT")
      CALL section_vals_get(rng_section, explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(rng_section, "_DEFAULT_KEYWORD_", &
                                   i_rep_val=1, c_val=rng_record)
         piglet_therm%gaussian_rng_stream = rng_stream_type_from_record(rng_record)
      ELSE
         initial_seed(:, :) = REAL(pint_env%thermostat_rng_seed, dp)
         piglet_therm%gaussian_rng_stream = rng_stream_type( &
                                            name="piglet_rng_gaussian", distribution_type=GAUSSIAN, &
                                            extended_precision=.TRUE., &
                                            seed=initial_seed)
      END IF

      !Compute the T and S matrices on every mpi process
      DO i = 1, p
         ! T = EXP(-A_mat*dt) = EXP(-A_mat*dt/2)
         ! Values for j and k = 15 are way to high, but to be sure.
         ! (its only executed once anyway)
         CALL gle_matrix_exp(M=(-0.5_dp*dt)*piglet_therm%a_mat(:, :, i), & !dt scaled A matrix
                             n=piglet_therm%nsp1, & !size of matrix
                             j=15, & !truncation for taylor expansion
                             k=15, & !scaling parameter for faster convergence of taylor expansion
                             EM=piglet_therm%gle_t(:, :, i)) !output T matrices
         ! S*TRANSPOSE(S) = C-T*C*TRANSPOSE(T)
         ! T*C:
         CALL DGEMM('N', & ! T-matrix is not transposed
                    'N', & ! C-matrix is not transposed
                    piglet_therm%nsp1, & ! number of rows of T-matrix
                    piglet_therm%nsp1, & ! number of columns of C-matrix
                    piglet_therm%nsp1, & ! number of columns of T-matrix and number of rows of C-matrix
                    1.0D0, & ! scaling factor alpha
                    piglet_therm%gle_t(:, :, i), & ! T-matrix
                    piglet_therm%nsp1, & ! leading dimension of T-matrix as declared
                    piglet_therm%c_mat(:, :, i), & ! C-matrix
                    piglet_therm%nsp1, & ! leading dimension of C-matrix as declared
                    0.0D0, & ! scaling of tmpmatrix as additive
                    tmpmatrix, & ! result matrix: tmpmatrix
                    piglet_therm%nsp1) ! leading dimension of tmpmatrix
         ! T*C*TRANSPOSE(T):
         CALL DGEMM('N', & ! tmpmatrix is not transposed
                    'T', & ! T-matrix is transposed
                    piglet_therm%nsp1, & ! number of rows of tmpmatrix
                    piglet_therm%nsp1, & ! number of columns of T-matrix
                    piglet_therm%nsp1, & ! number of columns of tmpmatrix and number of rows of T-matrix
                    1.0D0, & ! scaling factor alpha
                    tmpmatrix, & ! tmpmatrix
                    piglet_therm%nsp1, & ! leading dimension of tmpmatrix as declared
                    piglet_therm%gle_t(:, :, i), & ! T-matrix
                    piglet_therm%nsp1, & ! leading dimension of T-matrix as declared
                    0.0D0, & ! scaling of Mtmp as additive
                    Mtmp, & ! result matrix: Mtmp
                    piglet_therm%nsp1) ! leading dimension of Mtmp
         ! C - T*C*TRANSPOSE(T):
         Mtmp(:, :) = piglet_therm%c_mat(:, :, i) - Mtmp(:, :)

         IF (matrix_init == matrix_init_cholesky) THEN
            ! Get S by cholesky decomposition of Mtmp
            CALL gle_cholesky_stab(Mtmp, & ! Matrix to decompose
                                   piglet_therm%gle_s(:, :, i), & ! result
                                   piglet_therm%nsp1) ! Size of the matrix
         ELSE IF (matrix_init == matrix_init_diagonal) THEN
            ! Get S by full diagonalization of MTmp matrix
            CALL sqrt_pos_def_mat(piglet_therm%nsp1, & ! Size of the matrix
                                  Mtmp, & ! matrix to decompose
                                  piglet_therm%gle_s(:, :, i)) ! result
         END IF

      END DO

      ! Initialize extra degrees of freedom for Markovian Dynamics
      ! as a cholesky decomposition of C-matrix multiplied by a random number vector
      ! Or from restart
      piglet_therm%smalls = 0.0_dp
      NULLIFY (smalls_section)
      smalls_section => section_vals_get_subs_vals(section, subsection_name="EXTRA_DOF")
      CALL section_vals_get(smalls_section, explicit=explicit)
      IF (explicit) THEN
         NULLIFY (smallstmp)
         CALL section_vals_val_get(smalls_section, "_DEFAULT_KEYWORD_", &
                                   n_rep_val=ns)
         CALL section_vals_val_get(smalls_section, "_DEFAULT_KEYWORD_", &
                                   r_vals=smallstmp)
         i = 1
         DO isp = 2, piglet_therm%nsp1
            DO ibead = 1, piglet_therm%p*piglet_therm%ndim
               piglet_therm%smalls(isp, ibead) = smallstmp(i)
               i = i + 1
            END DO
         END DO
      ELSE
         DO ibead = 1, piglet_therm%p
            IF (matrix_init == matrix_init_cholesky) THEN
               CALL gle_cholesky_stab(piglet_therm%c_mat(:, :, ibead), & ! Matrix to decompose
                                      Mtmp, & ! Result
                                      piglet_therm%nsp1) ! Size of Matrix
            ELSE IF (matrix_init == matrix_init_diagonal) THEN
               ! Get S by full diagonalization of c_mat matrix
               CALL sqrt_pos_def_mat(piglet_therm%nsp1, & ! Size of the matrix
                                     piglet_therm%c_mat(:, :, ibead), & ! matrix to decompose
                                     Mtmp) ! result
            END IF
            ! Fill a vector with random numbers
            DO idim = 1, piglet_therm%ndim
               DO j = 1, piglet_therm%nsp1
                  piglet_therm%temp2(j, idim) = piglet_therm%gaussian_rng_stream%next()
                  !piglet_therm%temp2(j,idim) = 1.0_dp
               END DO
            END DO
            CALL DGEMM("N", & ! Matrix Mtmp is not transposed
                       "N", & ! Matrix temp2 is not transposed
                       piglet_therm%nsp1, & ! Number of rows of matrix Mtmp
                       piglet_therm%ndim, & ! Number of columns of matrix temp2
                       piglet_therm%nsp1, & ! Number of columns of matrix Mtmp
                       1.0_dp, & !scaling of Mtmp
                       Mtmp(1, 1), & ! Matrix Mtmp
                       piglet_therm%nsp1, & ! leading dimension of Mtmp
                       piglet_therm%temp2, & ! temp2 matrix
                       piglet_therm%nsp1, & ! leading dimension of temp2
                       0.0_dp, & ! scaling of added matrix smalls
                       piglet_therm%temp1, & ! result matrix
                       piglet_therm%nsp1) ! leading dimension of result matrix

            DO idim = 1, piglet_therm%ndim
               j = (idim - 1)*piglet_therm%p + ibead
               DO i = 1, piglet_therm%nsp1
                  piglet_therm%smalls(i, j) = piglet_therm%temp1(i, idim)
               END DO
            END DO
         END DO
      END IF

      !Fill the array for the sqrt of the masses
      DO idim = 1, piglet_therm%ndim
         DO ibead = 1, piglet_therm%p
            piglet_therm%sqrtmass(ibead, idim) = SQRT(pint_env%mass_fict(ibead, idim))
         END DO
      END DO

   END SUBROUTINE pint_piglet_init

! **************************************************************************************************
!> \brief ...
!> \param vold ...
!> \param vnew ...
!> \param first_mode ...
!> \param masses ...
!> \param piglet_therm ...
! **************************************************************************************************
   SUBROUTINE pint_piglet_step(vold, vnew, first_mode, masses, piglet_therm)
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: vold, vnew
      INTEGER, INTENT(IN)                                :: first_mode
      REAL(kind=dp), DIMENSION(:, :), INTENT(IN)         :: masses
      TYPE(piglet_therm_type), POINTER                   :: piglet_therm

      CHARACTER(len=*), PARAMETER                        :: routineN = 'pint_piglet_step'

      INTEGER                                            :: handle, i, ibead, idim, j, ndim, ndimp, &
                                                            nsp1, p
      REAL(KIND=dp)                                      :: delta_ekin

      CALL timeset(routineN, handle)
      nsp1 = piglet_therm%nsp1
      ndim = piglet_therm%ndim
      p = piglet_therm%p
      ndimp = ndim*p
      ! perform the following operation for all 3N*P
      ! smalls = gle_t*smalls + gle_s*rand_mat
      ! Copy mass scaled momenta to temp1 matrix
      ! p/sqrt(m) we use velocities so v*sqrt(m)
      DO ibead = first_mode, p
         ! Copy mass scaled momenta to temp1 matrix
         ! p/sqrt(m) we use velocities so v*sqrt(m)
         DO idim = 1, ndim
            piglet_therm%temp1(1, idim) = vold(ibead, idim)*piglet_therm%sqrtmass(ibead, idim)
         END DO
         ! copy the extra degrees of freedom to the temp1 matrix
         DO idim = 1, ndim
            DO i = 2, nsp1
               piglet_therm%temp1(i, idim) = piglet_therm%smalls(i, (ibead - 1)*ndim + idim)
            END DO
         END DO

         !fill temp2 with gaussian random noise
         DO j = 1, nsp1
            DO idim = 1, ndim
               piglet_therm%temp2(j, idim) = piglet_therm%gaussian_rng_stream%next()
               !piglet_therm%temp2(j,idim) = 1.0_dp
            END DO
         END DO

         i = (ibead - 1)*piglet_therm%ndim + 1
         !smalls(:,i) = 1*S*temp2 + 0 * smalls
         CALL DGEMM("N", & ! S-matrix should not be transposed
                    "N", & ! tmp2 matrix shoud not be transposed
                    nsp1, & ! Number of rows of S-Matrix
                    ndim, & ! Number of columns of temp2 vector
                    nsp1, & ! Number of Columns of S-Matrix
                    1.0_dp, & ! Scaling of S-Matrix
                    piglet_therm%gle_s(:, :, ibead), & ! S-matrix
                    nsp1, & ! Leading dimension of S-matrix
                    piglet_therm%temp2, & ! temp2 vector
                    nsp1, & ! Leading dimension of temp2
                    0.0_dp, & ! scaling factor of added smalls vector
                    piglet_therm%smalls(:, i), & ! result vector
                    nsp1) ! Leading dimension of result vector

         ! Now add the product of T-matrix * old smalls vectors
         ! smalls (:,i) = 1*T*temp1 + 1*smalls
         CALL DGEMM("N", & ! T-matrix should not be transposed
                    "N", & ! temp1 matrix shoud not be transposed
                    nsp1, & ! Number of rows of T-Matrix
                    ndim, & ! Number of columns of temp1 vector
                    nsp1, & ! Number of Columns of T-Matrix
                    1.0_dp, & ! Scaling of T-Matrix
                    piglet_therm%gle_t(:, :, ibead), & ! T-matrix
                    nsp1, & ! Leading dimension of T-matrix
                    piglet_therm%temp1, & ! temp1 vector
                    nsp1, & ! Leading dimension of temp1
                    1.0_dp, & ! scaling factor of added smalls vector
                    piglet_therm%smalls(:, i), & ! result vector
                    nsp1) ! Leading dimension of result vector
      END DO

      ! Copy the mass scales momenta to the outgoing velocities
      delta_ekin = 0.0_dp
      DO idim = 1, ndim
         DO ibead = 1, p
            vnew(ibead, idim) = piglet_therm%smalls(1, (ibead - 1)*ndim + idim)/piglet_therm%sqrtmass(ibead, idim)
            delta_ekin = delta_ekin + masses(ibead, idim)*( &
                         vnew(ibead, idim)*vnew(ibead, idim) - &
                         vold(ibead, idim)*vold(ibead, idim))
         END DO
      END DO

      ! the piglet is such a strong thermostat, that it messes up the "exact" integration. The thermostats energy will rise lineary, because "it will suck up its own mess" (quote from Michele Ceriotti)
      piglet_therm%thermostat_energy = piglet_therm%thermostat_energy - 0.5_dp*delta_ekin

      CALL timestop(handle)

   END SUBROUTINE pint_piglet_step

! ***************************************************************************
!> \brief releases the piglet environment
!> \param piglet_therm piglet data to be released
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE pint_piglet_release(piglet_therm)

      TYPE(piglet_therm_type), INTENT(INOUT)             :: piglet_therm

      DEALLOCATE (piglet_therm%a_mat)
      DEALLOCATE (piglet_therm%c_mat)
      DEALLOCATE (piglet_therm%gle_t)
      DEALLOCATE (piglet_therm%gle_s)
      DEALLOCATE (piglet_therm%smalls)
      DEALLOCATE (piglet_therm%temp1)
      DEALLOCATE (piglet_therm%temp2)
      DEALLOCATE (piglet_therm%sqrtmass)

   END SUBROUTINE pint_piglet_release

! ***************************************************************************
!> \brief adjust the unit of A MAT for piglet
!> \param a_mat ...
!> \param p ...
!> \param nsp1 ...
!> \param myunit ...
!> \param msg ...
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE a_mat_to_cp2k(a_mat, p, nsp1, myunit, msg)

      REAL(KIND=dp), DIMENSION(:, :, :), POINTER         :: a_mat
      INTEGER, INTENT(IN)                                :: p, nsp1
      CHARACTER(LEN=20), INTENT(IN)                      :: myunit
      CHARACTER(default_string_length), INTENT(OUT)      :: msg

      CHARACTER(LEN=20)                                  :: isunit
      INTEGER                                            :: i, imode, j

      msg = ""
      SELECT CASE (TRIM(myunit))
      CASE ("femtoseconds^-1")
         isunit = "fs^-1"
      CASE ("picoseconds^-1")
         isunit = "ps^-1"
      CASE ("seconds^-1")
         isunit = "s^-1"
      CASE ("atomic time units^-1")
         RETURN
      CASE DEFAULT
         msg = "Unknown unit of A-Matrices for PIGLET. Assuming a.u."
         CPWARN(msg)
         RETURN
      END SELECT

      DO imode = 1, p
         DO j = 1, nsp1
            DO i = 1, nsp1
               a_mat(i, j, imode) = cp_unit_to_cp2k(a_mat(i, j, imode), TRIM(isunit))
            END DO
         END DO
      END DO

   END SUBROUTINE
! ***************************************************************************
!> \brief adjust the unit of C MAT for piglet
!> \param c_mat ...
!> \param p ...
!> \param nsp1 ...
!> \param myunit ...
!> \param msg ...
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE c_mat_to_cp2k(c_mat, p, nsp1, myunit, msg)

      REAL(KIND=dp), DIMENSION(:, :, :), POINTER         :: c_mat
      INTEGER, INTENT(IN)                                :: p, nsp1
      CHARACTER(LEN=20), INTENT(IN)                      :: myunit
      CHARACTER(default_string_length), INTENT(OUT)      :: msg

      CHARACTER(LEN=20)                                  :: isunit
      INTEGER                                            :: i, imode, j

      msg = ""
      SELECT CASE (TRIM(myunit))
      CASE ("eV")
         isunit = "eV"
      CASE ("K")
         isunit = "K_e"
      CASE ("atomic energy units ")
         RETURN
      CASE DEFAULT
         msg = "Unknown unit of C-Matrices for PIGLET. Assuming a.u."
         CPWARN(msg)
         RETURN
      END SELECT

      DO imode = 1, p
         DO j = 1, nsp1
            DO i = 1, nsp1
               c_mat(i, j, imode) = cp_unit_to_cp2k(c_mat(i, j, imode), TRIM(isunit))
            END DO
         END DO
      END DO

   END SUBROUTINE c_mat_to_cp2k

! ***************************************************************************
!> \brief checks if the matrices are suited for the target temperature
!> \param line ...
!> \param propagator ...
!> \param targettemp ...
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE check_temperature(line, propagator, targettemp)

      CHARACTER(len=*), INTENT(IN)                       :: line
      INTEGER, INTENT(IN)                                :: propagator
      REAL(KIND=dp), INTENT(IN)                          :: targettemp

      CHARACTER(len=default_string_length)               :: msg
      INTEGER                                            :: posnumber
      REAL(KIND=dp)                                      :: convttemp, deviation, matrixtemp, ttemp

      deviation = 100.0d0
      posnumber = INDEX(line, "T=") + 2
      IF (propagator == propagator_rpmd) ttemp = targettemp
      !Get the matrix temperature
      READ (line(posnumber:), *) matrixtemp
      msg = ""
      IF (INDEX(line, "K") /= 0) THEN
         convttemp = cp_unit_from_cp2k(ttemp, "K")
         IF (ABS(convttemp - matrixtemp) > convttemp/deviation) THEN
            WRITE (UNIT=msg, FMT=*) "PIGLET Simulation temperature (", &
               convttemp, "K) /= matrix temperature (", matrixtemp, "K)"
            CPWARN(msg)
         END IF
      ELSE IF (INDEX(line, "eV") /= 0) THEN
         convttemp = cp_unit_from_cp2k(ttemp, "K")/11604.505_dp
         IF (ABS(convttemp - matrixtemp) > convttemp/deviation) THEN
            WRITE (UNIT=msg, FMT=*) "PIGLET Simulation temperature (", &
               convttemp, "K) /= matrix temperature (", matrixtemp, "K)"
            CPWARN(msg)
         END IF
      ELSE IF (INDEX(line, "atomic energy units") /= 0) THEN
         convttemp = ttemp
         IF (ABS(convttemp - matrixtemp) > convttemp/deviation) THEN
            WRITE (UNIT=msg, FMT=*) "PIGLET Simulation temperature (", &
               convttemp, "K) /= matrix temperature (", matrixtemp, "K)"
            CPWARN(msg)
         END IF
      ELSE
         WRITE (UNIT=msg, FMT=*) "Unknown PIGLET matrix temperature. Assuming a.u."
         CPWARN(msg)
         convttemp = ttemp
         IF (ABS(convttemp - matrixtemp) > convttemp/deviation) THEN
            WRITE (UNIT=msg, FMT=*) "PIGLET Simulation temperature (", &
               convttemp, "K) /= matrix temperature (", matrixtemp, "K)"
            CPWARN(msg)
         END IF
      END IF

   END SUBROUTINE check_temperature

! ***************************************************************************
!> \brief returns the piglet kinetic energy contribution
!> \param pint_env ...
!> \author Felix Uhl
! **************************************************************************************************
   ELEMENTAL SUBROUTINE pint_calc_piglet_energy(pint_env)
      TYPE(pint_env_type), INTENT(INOUT)                 :: pint_env

      IF (ASSOCIATED(pint_env%piglet_therm)) THEN
         pint_env%e_piglet = pint_env%piglet_therm%thermostat_energy
      ELSE
         pint_env%e_piglet = 0.0d0
      END IF

   END SUBROUTINE pint_calc_piglet_energy

! ***************************************************************************
!> \brief calculates S from S*TRANSPOSED(S) by diagonalizing
!>        if S*TRANSPOSED(S) is a positive definite matrix
!> \param n order of input matrix
!> \param SST matrix to be decomposed
!> \param S result matrix
!> \author Felix Uhl
! **************************************************************************************************
   SUBROUTINE sqrt_pos_def_mat(n, SST, S)

      INTEGER, INTENT(IN)                                :: n
      REAL(KIND=dp), DIMENSION(n, n), INTENT(IN)         :: SST
      REAL(KIND=dp), DIMENSION(n, n), INTENT(OUT)        :: S

      INTEGER                                            :: i, info, lwork
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: work
      REAL(KIND=dp), DIMENSION(1)                        :: tmplwork
      REAL(KIND=dp), DIMENSION(n)                        :: eigval
      REAL(KIND=dp), DIMENSION(n, n)                     :: A, tmpmatrix

! order of input matrix
! matrix to be decomposed
! result matrix
! Variables for eigenvalue/vector computation
! store matrix here to pass to lapack routine DSYEVR
! Array to contain the eigenvalues
! size of temporary real work array
! temporary real work array
! information about success
! counter

      eigval(:) = 0.0_dp
      A(:, :) = 0.0_dp
      A(:, :) = SST(:, :)

      !first call to figure out how big work array needs to be
      CALL dsyev('V', & ! Compute eigenvalues and eigenvectors
                 'U', & ! Store upper triagonal matrix
                 n, & ! order of matrix A to calculate the eigenvalues/vectors from
                 A, & ! Matrix to calculate the eigenvalues/vectors from
                 n, & ! leading order of matrix A
                 eigval, & ! Array to contain the eigenvalues
                 tmplwork, & ! temporary real work array
                 -1, & ! size of temporary real work array
                 info) ! information about success

      lwork = INT(tmplwork(1) + 0.5_dp)
      ALLOCATE (work(lwork))
      work(:) = 0.0_dp

      CALL dsyev('V', & ! Compute eigenvalues and eigenvectors
                 'U', & ! Store upper triagonal matrix
                 n, & ! order of matrix A to calculate the eigenvalues/vectors from
                 A, & ! Matrix to calculate the eigenvalues/vectors from
                 n, & ! leading order of matrix A
                 eigval, & ! Array to contain the eigenvalues
                 work, & ! temporary real work array
                 lwork, & ! size of temporary real work array
                 info) ! information about success
      DEALLOCATE (work)
      ! A-matrix now contains the eigenvectors

      S(:, :) = 0.0_dp
      DO i = 1, n
         ! In case that numerics made some eigenvalues negative
         IF (eigval(i) > 0.0_dp) THEN
            S(i, i) = SQRT(eigval(i))
         END IF
      END DO

      tmpmatrix(:, :) = 0.0_dp
      ! Transform matrix back
      !tmpmatrix = A*S
      CALL dgemm('N', & ! A-matrix is not transposed
                 'N', & ! S-matrix is not transposed
                 n, & ! number of rows of A-matrix
                 n, & ! number of columns of S-matrix
                 n, & ! number of columns of A-matrix and number of rows of S-matrix
                 1.0D0, & ! scaling factor of A-matrix
                 A, & ! A-matrix
                 n, & ! leading dimension of A-matrix as declared
                 S, & ! S-matrix
                 n, & ! leading dimension of S-matrix as declared
                 0.0D0, & ! scaling of tmpmatrix as additive
                 tmpmatrix, & ! result matrix: tmpmatrix
                 n) ! leading dimension of tmpmatrix
      !S = tmpmatrix*TRANSPOSE(A) = A*S*TRANSPOSE(A)
      CALL dgemm('N', & ! tmpmatrix not transposed
                 'T', & ! A-matrix is transposed
                 n, & ! number of rows of tmpmatrix
                 n, & ! number of columns of A-matrix
                 n, & ! number of columns of tmpmatrix and rows of A-matrix
                 1.0D0, & ! scaling factor of tmpmatrix
                 tmpmatrix, & ! tmpmatrix
                 n, & ! leading dimension of tmpmatrix as declared
                 A, & ! A-matrix
                 n, & ! leading dimension of A-matrix as declared
                 0.0D0, & ! scaling of S-matrix as additive
                 S, & ! result matrix: S-matrix
                 n) ! leading dimension of S-matrix as declared

   END SUBROUTINE sqrt_pos_def_mat

END MODULE pint_piglet
