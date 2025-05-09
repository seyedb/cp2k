!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!
MODULE optimize_basis
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_dbcsr_api,                    ONLY: dbcsr_p_type
   USE cp_dbcsr_operations,             ONLY: dbcsr_deallocate_matrix_set
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_release,&
                                              cp_fm_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type
   USE f77_interface,                   ONLY: create_force_env,&
                                              destroy_force_env,&
                                              f_env_add_defaults,&
                                              f_env_get_from_id,&
                                              f_env_rm_defaults,&
                                              f_env_type
   USE force_env_types,                 ONLY: force_env_get,&
                                              force_env_type
   USE input_cp2k_read,                 ONLY: empty_initial_variables,&
                                              read_input
   USE input_section_types,             ONLY: section_type,&
                                              section_vals_release,&
                                              section_vals_type
   USE kinds,                           ONLY: default_path_length,&
                                              dp
   USE machine,                         ONLY: m_chdir,&
                                              m_getcwd,&
                                              m_walltime
   USE message_passing,                 ONLY: mp_comm_type,&
                                              mp_para_env_release,&
                                              mp_para_env_type
   USE optbas_fenv_manipulation,        ONLY: allocate_mo_sets,&
                                              calculate_ks_matrix,&
                                              calculate_overlap_inverse,&
                                              modify_input_settings,&
                                              update_basis_set
   USE optbas_opt_utils,                ONLY: evaluate_optvals,&
                                              fit_mo_coeffs,&
                                              optbas_build_neighborlist
   USE optimize_basis_types,            ONLY: basis_optimization_type,&
                                              deallocate_basis_optimization_type,&
                                              subset_type
   USE optimize_basis_utils,            ONLY: get_set_and_basis_id,&
                                              optimize_basis_init_read_input,&
                                              update_derived_basis_sets
   USE powell,                          ONLY: powell_optimize
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_env_part_release,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: get_qs_kind_set,&
                                              qs_kind_type
   USE qs_ks_types,                     ONLY: get_ks_env,&
                                              qs_ks_env_type,&
                                              set_ks_env
   USE qs_mo_types,                     ONLY: allocate_mo_set,&
                                              deallocate_mo_set,&
                                              get_mo_set,&
                                              init_mo_set,&
                                              mo_set_type
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type,&
                                              release_neighbor_list_sets
   USE qs_neighbor_lists,               ONLY: build_qs_neighbor_lists
   USE qs_overlap,                      ONLY: build_overlap_matrix
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: run_optimize_basis

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'optimize_basis'

CONTAINS

! **************************************************************************************************
!> \brief main entry point for methods aimed at optimizing basis sets
!> \param input_declaration ...
!> \param root_section ...
!> \param para_env ...
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE run_optimize_basis(input_declaration, root_section, para_env)
      TYPE(section_type), POINTER                        :: input_declaration
      TYPE(section_vals_type), POINTER                   :: root_section
      TYPE(mp_para_env_type), POINTER                    :: para_env

      CHARACTER(len=*), PARAMETER :: routineN = 'run_optimize_basis'

      INTEGER                                            :: handle
      TYPE(basis_optimization_type)                      :: opt_bas

      CALL timeset(routineN, handle)

      CALL optimize_basis_init_read_input(opt_bas, root_section, para_env)

      CALL driver_para_opt_basis(opt_bas, input_declaration, para_env)

      CALL deallocate_basis_optimization_type(opt_bas)
      CALL timestop(handle)

   END SUBROUTINE run_optimize_basis

! **************************************************************************************************
!> \brief driver routine for the parallel part of the method
!> \param opt_bas ...
!> \param input_declaration ...
!> \param para_env ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE driver_para_opt_basis(opt_bas, input_declaration, para_env)
      TYPE(basis_optimization_type)                      :: opt_bas
      TYPE(section_type), POINTER                        :: input_declaration
      TYPE(mp_para_env_type), POINTER                    :: para_env

      CHARACTER(len=*), PARAMETER :: routineN = 'driver_para_opt_basis'

      INTEGER                                            :: handle, n_groups_created
      TYPE(mp_comm_type)                                 :: opt_group
      INTEGER, DIMENSION(:), POINTER                     :: group_distribution_p
      INTEGER, DIMENSION(0:para_env%num_pe-1), TARGET    :: group_distribution

      CALL timeset(routineN, handle)
      group_distribution_p => group_distribution
      CALL opt_group%from_split(para_env, n_groups_created, group_distribution_p, &
                                n_subgroups=SIZE(opt_bas%group_partition), group_partition=opt_bas%group_partition)
      opt_bas%opt_id = group_distribution(para_env%mepos) + 1
      opt_bas%n_groups_created = n_groups_created
      ALLOCATE (opt_bas%sub_sources(0:para_env%num_pe - 1))

      CALL driver_optimization_para_low(opt_bas, input_declaration, para_env, opt_group)

      CALL opt_group%free()
      CALL timestop(handle)

   END SUBROUTINE driver_para_opt_basis

! **************************************************************************************************
!> \brief low level optimization routine includes initialization of the subsytems
!>        powell optimizer and deallocation of the various force envs
!> \param opt_bas ...
!> \param input_declaration ...
!> \param para_env_top ...
!> \param mpi_comm_opt ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE driver_optimization_para_low(opt_bas, input_declaration, para_env_top, mpi_comm_opt)
      TYPE(basis_optimization_type)                      :: opt_bas
      TYPE(section_type), POINTER                        :: input_declaration
      TYPE(mp_para_env_type), POINTER                    :: para_env_top
      TYPE(mp_comm_type), INTENT(IN)                     :: mpi_comm_opt

      CHARACTER(len=*), PARAMETER :: routineN = 'driver_optimization_para_low'

      INTEGER                                            :: handle, icalc, iopt, is, mp_id, stat
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: f_env_id
      LOGICAL                                            :: write_basis
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: tot_time
      TYPE(cp_fm_type), ALLOCATABLE, DIMENSION(:)        :: matrix_S_inv
      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(mp_para_env_type), POINTER                    :: para_env

      NULLIFY (f_env)

      CALL timeset(routineN, handle)

      ! ======  initialize the f_env and precompute some matrices =====
      mp_id = opt_bas%opt_id
      NULLIFY (para_env, f_env)
      ALLOCATE (f_env_id(SIZE(opt_bas%comp_group(mp_id)%member_list)))
      ALLOCATE (tot_time(opt_bas%ncombinations*opt_bas%ntraining_sets))
      ALLOCATE (matrix_s_inv(SIZE(opt_bas%comp_group(mp_id)%member_list)))

      ALLOCATE (para_env)
      para_env = mpi_comm_opt

      is = -1
      IF (para_env%is_source()) is = para_env_top%mepos
      CALL para_env_top%allgather(is, opt_bas%sub_sources)

      CALL init_training_force_envs(opt_bas, f_env_id, input_declaration, matrix_s_inv, para_env, mpi_comm_opt)

      CALL init_free_vars(opt_bas)
      tot_time = 0.0_dp

      ! ======= The real optimization loop  =======
      DO iopt = 0, opt_bas%powell_param%maxfun
         CALL compute_residuum_vectors(opt_bas, f_env_id, matrix_S_inv, tot_time, &
                                       para_env_top, para_env, iopt)
         IF (para_env_top%is_source()) &
            CALL powell_optimize(opt_bas%powell_param%nvar, opt_bas%x_opt, opt_bas%powell_param)
         CALL para_env_top%bcast(opt_bas%powell_param%state)
         CALL para_env_top%bcast(opt_bas%x_opt)
         CALL update_free_vars(opt_bas)
         write_basis = MOD(iopt, opt_bas%write_frequency) == 0
         CALL update_derived_basis_sets(opt_bas, write_basis, opt_bas%output_basis_file, &
                                        para_env_top)
         IF (opt_bas%powell_param%state == -1) EXIT
      END DO

      ! ======= Update the basis set and print the final basis  =======
      IF (para_env_top%is_source()) THEN
         opt_bas%powell_param%state = 8
         CALL powell_optimize(opt_bas%powell_param%nvar, opt_bas%x_opt, opt_bas%powell_param)
      END IF

      CALL para_env_top%bcast(opt_bas%x_opt)
      CALL update_free_vars(opt_bas)
      CALL update_derived_basis_sets(opt_bas, .TRUE., opt_bas%output_basis_file, &
                                     para_env_top)

      ! ======  get rid of the f_env again =====

      DO icalc = SIZE(opt_bas%comp_group(mp_id)%member_list), 1, -1
         CALL f_env_get_from_id(f_env_id(icalc), f_env)
         CALL destroy_force_env(f_env_id(icalc), stat)
      END DO
      DEALLOCATE (f_env_id); DEALLOCATE (tot_time)
      CALL cp_fm_release(matrix_s_inv)
      CALL mp_para_env_release(para_env)
      CALL timestop(handle)

   END SUBROUTINE driver_optimization_para_low

! **************************************************************************************************
!> \brief compute all ingredients for powell optimizer. Rho_diff,
!>        condition number, energy,... for all ttraining sets in
!>        the computational group
!> \param opt_bas ...
!> \param f_env_id ...
!> \param matrix_S_inv ...
!> \param tot_time ...
!> \param para_env_top ...
!> \param para_env ...
!> \param iopt ...
! **************************************************************************************************

   SUBROUTINE compute_residuum_vectors(opt_bas, f_env_id, matrix_S_inv, tot_time, &
                                       para_env_top, para_env, iopt)
      TYPE(basis_optimization_type)                      :: opt_bas
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: f_env_id
      TYPE(cp_fm_type), DIMENSION(:), INTENT(IN)         :: matrix_S_inv
      REAL(KIND=dp), DIMENSION(:)                        :: tot_time
      TYPE(mp_para_env_type), POINTER                    :: para_env_top, para_env
      INTEGER                                            :: iopt

      CHARACTER(len=*), PARAMETER :: routineN = 'compute_residuum_vectors'

      CHARACTER(len=8)                                   :: basis_type
      INTEGER                                            :: bas_id, handle, icalc, icomb, ispin, &
                                                            mp_id, my_id, nao, ncalc, nelectron, &
                                                            nmo, nspins, set_id
      REAL(KIND=dp)                                      :: flexible_electron_count, maxocc, n_el_f
      REAL(KIND=dp), DIMENSION(:), POINTER               :: cond_vec, energy, f_vec, my_time, &
                                                            start_time
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: gdata
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_ks, matrix_s_aux, matrix_s_aux_orb
      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(force_env_type), POINTER                      :: force_env
      TYPE(mo_set_type), ALLOCATABLE, DIMENSION(:)       :: mos_aux
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_aux, sab_aux_orb
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_ks_env_type), POINTER                      :: ks_env

      CALL timeset(routineN, handle)

      basis_type = "AUX_OPT"
      !
      ncalc = opt_bas%ncombinations*opt_bas%ntraining_sets
      ALLOCATE (gdata(ncalc, 4))
      f_vec => gdata(:, 1)
      my_time => gdata(:, 2)
      cond_vec => gdata(:, 3)
      energy => gdata(:, 4)
      !
      f_vec = 0.0_dp; cond_vec = 0.0_dp; my_time = 0.0_dp; energy = 0.0_dp
      mp_id = opt_bas%opt_id
      ALLOCATE (start_time(SIZE(opt_bas%comp_group(mp_id)%member_list)))
      !
      DO icalc = 1, SIZE(opt_bas%comp_group(mp_id)%member_list)
         my_id = opt_bas%comp_group(mp_id)%member_list(icalc) + 1
         ! setup timings
         start_time(icalc) = m_walltime()

         NULLIFY (matrix_s_aux_orb, matrix_s_aux)
         CALL get_set_and_basis_id(opt_bas%comp_group(mp_id)%member_list(icalc), opt_bas, set_id, bas_id)
         CALL f_env_get_from_id(f_env_id(icalc), f_env)
         force_env => f_env%force_env
         CALL force_env_get(force_env, qs_env=qs_env)
         CALL get_qs_env(qs_env, ks_env=ks_env)
         CALL update_basis_set(opt_bas, bas_id, basis_type, qs_env)
         NULLIFY (sab_aux, sab_aux_orb)
         CALL optbas_build_neighborlist(qs_env, sab_aux, sab_aux_orb, basis_type)
         CALL build_overlap_matrix(ks_env, matrix_s=matrix_s_aux, &
                                   basis_type_a=basis_type, &
                                   basis_type_b=basis_type, &
                                   sab_nl=sab_aux)
         CALL build_overlap_matrix(ks_env, matrix_s=matrix_s_aux_orb, &
                                   basis_type_a=basis_type, &
                                   basis_type_b="ORB", &
                                   sab_nl=sab_aux_orb)
         CALL release_neighbor_list_sets(sab_aux)
         CALL release_neighbor_list_sets(sab_aux_orb)
         CALL get_qs_env(qs_env, mos=mos, matrix_ks=matrix_ks)

         nspins = SIZE(mos)
         ALLOCATE (mos_aux(nspins))
         CALL get_qs_env(qs_env, qs_kind_set=qs_kind_set)
         CALL get_qs_kind_set(qs_kind_set, nsgf=nao, basis_type=basis_type)
         DO ispin = 1, nspins
            CALL get_mo_set(mo_set=mos(ispin), mo_coeff=mo_coeff, maxocc=maxocc, nelectron=nelectron, &
                            n_el_f=n_el_f, nmo=nmo, flexible_electron_count=flexible_electron_count)
            CALL cp_fm_struct_create(fm_struct, nrow_global=nao, ncol_global=nmo, &
                                     context=mo_coeff%matrix_struct%context, &
                                     para_env=mo_coeff%matrix_struct%para_env)
            CALL allocate_mo_set(mos_aux(ispin), nao, nmo, nelectron, &
                                 n_el_f, maxocc, flexible_electron_count)
            CALL init_mo_set(mo_set=mos_aux(ispin), fm_struct=fm_struct, name="MO_AUX")
            CALL cp_fm_struct_release(fm_struct)
         END DO

         CALL fit_mo_coeffs(matrix_s_aux, matrix_s_aux_orb, mos, mos_aux)
         CALL evaluate_optvals(mos, mos_aux, matrix_ks, matrix_s_aux_orb(1)%matrix, &
                               matrix_s_aux(1)%matrix, matrix_S_inv(icalc), &
                               f_vec(my_id), energy(my_id), cond_vec(my_id))

         DO ispin = 1, nspins
            CALL deallocate_mo_set(mos_aux(ispin))
         END DO
         DEALLOCATE (mos_aux)
         IF (ASSOCIATED(matrix_s_aux)) CALL dbcsr_deallocate_matrix_set(matrix_s_aux)
         IF (ASSOCIATED(matrix_s_aux_orb)) CALL dbcsr_deallocate_matrix_set(matrix_s_aux_orb)

         my_time(my_id) = m_walltime() - start_time(icalc)
      END DO

      DEALLOCATE (start_time)

      IF (.NOT. para_env%is_source()) THEN
         f_vec = 0.0_dp; cond_vec = 0.0_dp; my_time = 0.0_dp; energy = 0.0_dp
      END IF
      ! collect date from all subgroup ionodes on the main ionode
      CALL para_env_top%sum(gdata)

      opt_bas%powell_param%f = 0.0_dp
      IF (para_env_top%is_source()) THEN
         DO icalc = 1, SIZE(f_vec)
            icomb = MOD(icalc - 1, opt_bas%ncombinations)
            opt_bas%powell_param%f = opt_bas%powell_param%f + &
                                     (f_vec(icalc) + energy(icalc))*opt_bas%fval_weight(icomb)
            IF (opt_bas%use_condition_number) &
               opt_bas%powell_param%f = opt_bas%powell_param%f + &
                                        LOG(cond_vec(icalc))*opt_bas%condition_weight(icomb)
         END DO
      ELSE
         f_vec = 0.0_dp; cond_vec = 0.0_dp; my_time = 0.0_dp; energy = 0.0_dp
      END IF
      CALL para_env_top%bcast(opt_bas%powell_param%f)

      ! output info if required
      CALL output_opt_info(f_vec, cond_vec, my_time, tot_time, opt_bas, iopt, para_env_top)
      DEALLOCATE (gdata)

      CALL para_env_top%sync()

      CALL timestop(handle)

   END SUBROUTINE compute_residuum_vectors

! **************************************************************************************************
!> \brief create the force_envs for every input in the computational group
!> \param opt_bas ...
!> \param f_env_id ...
!> \param input_declaration ...
!> \param matrix_s_inv ...
!> \param para_env ...
!> \param mpi_comm_opt ...
! **************************************************************************************************

   SUBROUTINE init_training_force_envs(opt_bas, f_env_id, input_declaration, matrix_s_inv, para_env, mpi_comm_opt)

      TYPE(basis_optimization_type)                      :: opt_bas
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: f_env_id
      TYPE(section_type), POINTER                        :: input_declaration
      TYPE(cp_fm_type), DIMENSION(:), INTENT(OUT)        :: matrix_S_inv
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(mp_comm_type)                                 :: mpi_comm_opt

      CHARACTER(len=*), PARAMETER :: routineN = 'init_training_force_envs'

      CHARACTER(len=default_path_length)                 :: main_dir
      INTEGER                                            :: bas_id, handle, icalc, ierr, mp_id, &
                                                            set_id, stat
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(force_env_type), POINTER                      :: force_env
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(section_vals_type), POINTER                   :: input_file

      CALL timeset(routineN, handle)

      NULLIFY (matrix_s, blacs_env, ks_env)

      mp_id = opt_bas%opt_id
      CALL m_getcwd(main_dir)

      ! ======= Create f_env for all calculations in MPI group =======
      DO icalc = 1, SIZE(opt_bas%comp_group(mp_id)%member_list)
         NULLIFY (input_file)
         ! parse the input of the training sets
         CALL get_set_and_basis_id(opt_bas%comp_group(mp_id)%member_list(icalc), opt_bas, set_id, bas_id)
         CALL m_chdir(TRIM(opt_bas%training_dir(set_id)), ierr)
         IF (ierr /= 0) THEN
            CALL cp_abort(__LOCATION__, &
                          "Could not change to directory <"//TRIM(opt_bas%training_dir(set_id))//">")
         END IF
         input_file => read_input(input_declaration, &
                                  opt_bas%training_input(set_id), &
                                  initial_variables=empty_initial_variables, &
                                  para_env=para_env)

         CALL modify_input_settings(opt_bas, bas_id, input_file)
         CALL create_force_env(f_env_id(icalc), &
                               input_declaration=input_declaration, &
                               input_path=opt_bas%training_input(set_id), &
                               input=input_file, &
                               output_path="scrap_information", &
                               mpi_comm=mpi_comm_opt, &
                               ierr=stat)

         ! some weirdness with the default stacks defaults have to be addded to get the
         ! correct default program name this causes trouble with the timer stack if kept
         CALL f_env_add_defaults(f_env_id(icalc), f_env)
         force_env => f_env%force_env
         CALL force_env_get(force_env, qs_env=qs_env)
         CALL allocate_mo_sets(qs_env)
         CALL f_env_rm_defaults(f_env, stat)
         CALL get_qs_env(qs_env, ks_env=ks_env)
         CALL build_qs_neighbor_lists(qs_env, para_env, molecular=.FALSE., &
                                      force_env_section=qs_env%input)
         CALL get_ks_env(ks_env, &
                         matrix_s=matrix_s, &
                         sab_orb=sab_orb)
         CALL build_overlap_matrix(ks_env, matrix_s=matrix_s, &
                                   matrix_name="OVERLAP", &
                                   basis_type_a="ORB", &
                                   basis_type_b="ORB", &
                                   sab_nl=sab_orb)
         CALL set_ks_env(ks_env, matrix_s=matrix_s)
         CALL get_qs_env(qs_env, matrix_s=matrix_s, blacs_env=blacs_env)
         CALL calculate_overlap_inverse(matrix_s(1)%matrix, matrix_s_inv(icalc), &
                                        para_env, blacs_env)
         CALL calculate_ks_matrix(qs_env)

         CALL section_vals_release(input_file)

         CALL qs_env_part_release(qs_env)

         CALL m_chdir(TRIM(ADJUSTL(main_dir)), ierr)
      END DO

      CALL timestop(handle)

   END SUBROUTINE init_training_force_envs

! **************************************************************************************************
!> \brief variable update from the powell vector for all sets
!> \param opt_bas ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE update_free_vars(opt_bas)
      TYPE(basis_optimization_type)                      :: opt_bas

      CHARACTER(len=*), PARAMETER                        :: routineN = 'update_free_vars'

      INTEGER                                            :: handle, ikind, iset, ix

      CALL timeset(routineN, handle)
      ix = 0
      DO ikind = 1, opt_bas%nkind
         DO iset = 1, opt_bas%kind_basis(ikind)%flex_basis(0)%nsets
            CALL update_subset_freevars(opt_bas%kind_basis(ikind)%flex_basis(0)%subset(iset), ix, opt_bas%x_opt)
         END DO
      END DO
      CALL timestop(handle)

   END SUBROUTINE update_free_vars

! **************************************************************************************************
!> \brief low level update for the basis sets. Exponents are transformed according to constraint
!> \param subset ...
!> \param ix ...
!> \param x ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE update_subset_freevars(subset, ix, x)
      TYPE(subset_type)                                  :: subset
      INTEGER                                            :: ix
      REAL(KIND=dp), DIMENSION(:)                        :: x

      CHARACTER(len=*), PARAMETER :: routineN = 'update_subset_freevars'

      INTEGER                                            :: handle, icon1, icon2, icont, iexp, il, &
                                                            istart
      REAL(KIND=dp)                                      :: fermi_f, gs_scale

      CALL timeset(routineN, handle)
      DO iexp = 1, subset%nexp
         IF (subset%opt_exps(iexp)) THEN
            ix = ix + 1
            subset%exps(iexp) = ABS(x(ix))
            IF (subset%exp_has_const(iexp)) THEN
               !use a fermi function to keep exponents in a given range around their initial value
               fermi_f = 1.0_dp/(EXP((x(ix) - 1.0_dp)/0.5_dp) + 1.0_dp)
               subset%exps(iexp) = (2.0_dp*fermi_f - 1.0_dp)*subset%exp_const(iexp)%var_fac*subset%exp_const(iexp)%init + &
                                   subset%exp_const(iexp)%init
            ELSE

            END IF
         END IF
         DO icont = 1, subset%ncon_tot
            IF (subset%opt_coeff(iexp, icont)) THEN
               ix = ix + 1
               subset%coeff(iexp, icont) = x(ix)
            END IF
         END DO
      END DO

      ! orthonormalize contraction coefficients using gram schmidt
      istart = 1
      DO il = 1, subset%nl
         DO icon1 = istart, istart + subset%l(il) - 2
            DO icon2 = icon1 + 1, istart + subset%l(il) - 1
               gs_scale = DOT_PRODUCT(subset%coeff(:, icon2), subset%coeff(:, icon1))/ &
                          DOT_PRODUCT(subset%coeff(:, icon1), subset%coeff(:, icon1))
               subset%coeff(:, icon2) = subset%coeff(:, icon2) - gs_scale*subset%coeff(:, icon1)
            END DO
         END DO
         istart = istart + subset%l(il)
      END DO

      DO icon1 = 1, subset%ncon_tot
         subset%coeff(:, icon1) = subset%coeff(:, icon1)/ &
                                  SQRT(DOT_PRODUCT(subset%coeff(:, icon1), subset%coeff(:, icon1)))
      END DO
      CALL timestop(handle)

   END SUBROUTINE update_subset_freevars

! **************************************************************************************************
!> \brief variable initialization for the powell vector for all sets
!> \param opt_bas ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE init_free_vars(opt_bas)
      TYPE(basis_optimization_type)                      :: opt_bas

      CHARACTER(len=*), PARAMETER                        :: routineN = 'init_free_vars'

      INTEGER                                            :: handle, ikind, iset, ix

      CALL timeset(routineN, handle)
      ix = 0
      DO ikind = 1, opt_bas%nkind
         DO iset = 1, opt_bas%kind_basis(ikind)%flex_basis(0)%nsets
            CALL init_subset_freevars(opt_bas%kind_basis(ikind)%flex_basis(0)%subset(iset), ix, opt_bas%x_opt)
         END DO
      END DO
      CALL timestop(handle)

   END SUBROUTINE init_free_vars

! **************************************************************************************************
!> \brief variable initialization for the powell vector from low level informations
!>        constraint exponents will be mapped on a fermi function
!> \param subset ...
!> \param ix ...
!> \param x ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE init_subset_freevars(subset, ix, x)
      TYPE(subset_type)                                  :: subset
      INTEGER                                            :: ix
      REAL(KIND=dp), DIMENSION(:)                        :: x

      CHARACTER(len=*), PARAMETER :: routineN = 'init_subset_freevars'

      INTEGER                                            :: handle, icont, iexp
      REAL(KIND=dp)                                      :: fract

      CALL timeset(routineN, handle)

      DO iexp = 1, subset%nexp
         IF (subset%opt_exps(iexp)) THEN
            ix = ix + 1
            x(ix) = subset%exps(iexp)
            IF (subset%exp_has_const(iexp)) THEN
               IF (subset%exp_const(iexp)%const_type == 0) THEN
                  fract = 1.0_dp + (subset%exps(iexp) - subset%exp_const(iexp)%init)/ &
                          (subset%exp_const(iexp)%init*subset%exp_const(iexp)%var_fac)
                  x(ix) = 0.5_dp*LOG((2.0_dp/fract - 1.0_dp)) + 1.0_dp
               END IF
               IF (subset%exp_const(iexp)%const_type == 1) THEN
                  x(ix) = 1.0_dp
               END IF
            END IF
         END IF
         DO icont = 1, subset%ncon_tot
            IF (subset%opt_coeff(iexp, icont)) THEN
               ix = ix + 1
               x(ix) = subset%coeff(iexp, icont)
            END IF
         END DO
      END DO
      CALL timestop(handle)

   END SUBROUTINE init_subset_freevars

! **************************************************************************************************
!> \brief commuticates all info to the master and assembles the output
!> \param f_vec ...
!> \param cond_vec ...
!> \param my_time ...
!> \param tot_time ...
!> \param opt_bas ...
!> \param iopt ...
!> \param para_env_top ...
!> \author Florian Schiffmann
! **************************************************************************************************

   SUBROUTINE output_opt_info(f_vec, cond_vec, my_time, tot_time, opt_bas, iopt, para_env_top)
      REAL(KIND=dp), DIMENSION(:)                        :: f_vec, cond_vec, my_time, tot_time
      TYPE(basis_optimization_type)                      :: opt_bas
      INTEGER                                            :: iopt
      TYPE(mp_para_env_type), POINTER                    :: para_env_top

      CHARACTER(len=*), PARAMETER                        :: routineN = 'output_opt_info'

      INTEGER                                            :: handle, ibasis, icalc, iset, unit_nr
      TYPE(cp_logger_type), POINTER                      :: logger

      CALL timeset(routineN, handle)
      logger => cp_get_default_logger()

      tot_time = tot_time + my_time

      unit_nr = -1
      IF (para_env_top%is_source() .AND. (MOD(iopt, opt_bas%write_frequency) == 0 .OR. iopt == opt_bas%powell_param%maxfun)) &
         unit_nr = cp_logger_get_default_unit_nr(logger)

      IF (unit_nr .GT. 0) THEN
         WRITE (unit_nr, '(1X,A,I8)') "BASOPT| Information at iteration number:", iopt
         WRITE (unit_nr, '(1X,A)') "BASOPT| Training set | Combination | Rho difference | Condition num. | Time"
         WRITE (unit_nr, '(1X,A)') "BASOPT| -----------------------------------------------------------------------"
         icalc = 0
         DO iset = 1, opt_bas%ntraining_sets
            DO ibasis = 1, opt_bas%ncombinations
               icalc = icalc + 1
               WRITE (unit_nr, '(1X,A,2(5X,I3,5X,A),2(1X,E14.8,1X,A),1X,F8.1)') &
                  'BASOPT| ', iset, "|", ibasis, "|", f_vec(icalc), "|", cond_vec(icalc), "|", tot_time(icalc)
            END DO
         END DO
         WRITE (unit_nr, '(1X,A)') "BASOPT| -----------------------------------------------------------------------"
         WRITE (unit_nr, '(1X,A,E14.8)') "BASOPT| Total residuum value: ", opt_bas%powell_param%f
         WRITE (unit_nr, '(A)') ""
      END IF
      CALL timestop(handle)
   END SUBROUTINE output_opt_info

END MODULE optimize_basis

