!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Definition and initialisation of the mo data type.
!> \par History
!>      - adapted to the new QS environment data structure (02.04.2002,MK)
!>      - set_mo_occupation added (17.04.02,MK)
!>      - correct_mo_eigenvalues added (18.04.02,MK)
!>      - calculate_density_matrix moved from qs_scf to here (22.04.02,MK)
!>      - mo_set_p_type added (23.04.02,MK)
!>      - PRIVATE attribute set for TYPE mo_set_type (23.04.02,MK)
!>      - started conversion to LSD (1.2003, Joost VandeVondele)
!>      - set_mo_occupation moved to qs_mo_occupation (11.12.14 MI)
!>      - correct_mo_eigenvalues moved to qs_scf_methods (03.2016, Sergey Chulkov)
!> \author Matthias Krack (09.05.2001,MK)
! **************************************************************************************************
MODULE qs_mo_types

   USE cp_dbcsr_api,                    ONLY: dbcsr_copy,&
                                              dbcsr_init_p,&
                                              dbcsr_release_p,&
                                              dbcsr_type
   USE cp_dbcsr_operations,             ONLY: dbcsr_copy_columns_hack
   USE cp_fm_pool_types,                ONLY: cp_fm_pool_type,&
                                              fm_pool_create_fm
   USE cp_fm_struct,                    ONLY: cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_release,&
                                              cp_fm_to_fm,&
                                              cp_fm_type
   USE kinds,                           ONLY: dp
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_mo_types'

   TYPE mo_set_type
      ! The actual MO coefficients as a matrix
      TYPE(cp_fm_type), POINTER                          :: mo_coeff => NULL()
      TYPE(dbcsr_type), POINTER                          :: mo_coeff_b => NULL()
      ! we are using the dbcsr mo_coeff_b
      LOGICAL                                            :: use_mo_coeff_b = .FALSE.
      ! Number of molecular orbitals (# cols in mo_coeff)
      INTEGER                                            :: nmo = -1
      ! Number of atomic orbitals (# rows in mo_coeff)
      INTEGER                                            :: nao = -1
      ! MO occupation numbers and MO eigenvalues (if eigenstates)
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigenvalues => NULL(), &
                                                            occupation_numbers => NULL()
      ! Maximum allowed occupation number of an MO, i.e.
      ! 1 for spin unrestricted (polarized) and 2 for spin restricted
      REAL(KIND=dp)                                      :: maxocc = -1
      ! Number of electrons (taking occupations into account)
      INTEGER                                            :: nelectron = -1
      REAL(KIND=dp)                                      :: n_el_f = -1.0_dp
      ! Highest orbital with non-zero occupation
      INTEGER                                            :: homo = -1
      ! lowest non maxocc occupied orbital (e.g. fractional or zero)
      INTEGER                                            :: lfomo = -1
      ! True, if all allocated MOs have the same occupation number.
      ! This is not the case for fractional occupations or for added MOs
      ! with zero occupation.
      LOGICAL                                            :: uniform_occupation = .FALSE.
      ! The entropic energy contribution
      REAL(KIND=dp)                                      :: kTS = -1.0_dp
      ! Fermi energy level
      REAL(KIND=dp)                                      :: mu = 0.0_dp
      ! Threshold value for multiplicity change
      REAL(KIND=dp)                                      :: flexible_electron_count = -1.0_dp
   END TYPE mo_set_type

   TYPE mo_set_p_type
      TYPE(mo_set_type), POINTER :: mo_set => NULL()
   END TYPE mo_set_p_type

   PUBLIC :: mo_set_p_type, &
             mo_set_type

   PUBLIC :: allocate_mo_set, &
             deallocate_mo_set, &
             duplicate_mo_set, &
             get_mo_set, &
             has_uniform_occupation, &
             init_mo_set, &
             mo_set_restrict, &
             reassign_allocated_mos, &
             set_mo_set

CONTAINS

! **************************************************************************************************
!> \brief reassign an already allocated mo_set
!> \param mo_set_new ...
!> \param mo_set_old ...
!> \date 2019-05-16
!> \par History
!> \author Soumya Ghosh
! **************************************************************************************************
   SUBROUTINE reassign_allocated_mos(mo_set_new, mo_set_old)
      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set_new, mo_set_old

      INTEGER                                            :: nmo

      mo_set_new%maxocc = mo_set_old%maxocc
      mo_set_new%nelectron = mo_set_old%nelectron
      mo_set_new%n_el_f = mo_set_old%n_el_f
      mo_set_new%nao = mo_set_old%nao
      mo_set_new%nmo = mo_set_old%nmo
      mo_set_new%homo = mo_set_old%homo
      mo_set_new%lfomo = mo_set_old%lfomo
      mo_set_new%uniform_occupation = mo_set_old%uniform_occupation
      mo_set_new%kTS = mo_set_old%kTS
      mo_set_new%mu = mo_set_old%mu
      mo_set_new%flexible_electron_count = mo_set_old%flexible_electron_count

      nmo = mo_set_new%nmo

      CALL cp_fm_to_fm(mo_set_old%mo_coeff, mo_set_new%mo_coeff)

      !IF (ASSOCIATED(mo_set_old%mo_coeff_b)) THEN
      !   CALL dbcsr_copy(mo_set_new%mo_coeff_b, mo_set_old%mo_coeff_b)
      !END IF
      !mo_set_new%use_mo_coeff_b = mo_set_old%use_mo_coeff_b

      mo_set_new%eigenvalues = mo_set_old%eigenvalues

      mo_set_new%occupation_numbers = mo_set_old%occupation_numbers

   END SUBROUTINE reassign_allocated_mos

! **************************************************************************************************
!> \brief allocate a new mo_set, and copy the old data
!> \param mo_set_new ...
!> \param mo_set_old ...
!> \date 2009-7-19
!> \par History
!> \author Joost VandeVondele
! **************************************************************************************************
   SUBROUTINE duplicate_mo_set(mo_set_new, mo_set_old)
      TYPE(mo_set_type), INTENT(OUT)                     :: mo_set_new
      TYPE(mo_set_type), INTENT(IN)                      :: mo_set_old

      INTEGER                                            :: nmo

      mo_set_new%maxocc = mo_set_old%maxocc
      mo_set_new%nelectron = mo_set_old%nelectron
      mo_set_new%n_el_f = mo_set_old%n_el_f
      mo_set_new%nao = mo_set_old%nao
      mo_set_new%nmo = mo_set_old%nmo
      mo_set_new%homo = mo_set_old%homo
      mo_set_new%lfomo = mo_set_old%lfomo
      mo_set_new%uniform_occupation = mo_set_old%uniform_occupation
      mo_set_new%kTS = mo_set_old%kTS
      mo_set_new%mu = mo_set_old%mu
      mo_set_new%flexible_electron_count = mo_set_old%flexible_electron_count

      nmo = mo_set_new%nmo

      NULLIFY (mo_set_new%mo_coeff)
      ALLOCATE (mo_set_new%mo_coeff)
      CALL cp_fm_create(mo_set_new%mo_coeff, mo_set_old%mo_coeff%matrix_struct)
      CALL cp_fm_to_fm(mo_set_old%mo_coeff, mo_set_new%mo_coeff)

      NULLIFY (mo_set_new%mo_coeff_b)
      IF (ASSOCIATED(mo_set_old%mo_coeff_b)) THEN
         CALL dbcsr_init_p(mo_set_new%mo_coeff_b)
         CALL dbcsr_copy(mo_set_new%mo_coeff_b, mo_set_old%mo_coeff_b)
      END IF
      mo_set_new%use_mo_coeff_b = mo_set_old%use_mo_coeff_b

      ALLOCATE (mo_set_new%eigenvalues(nmo))
      mo_set_new%eigenvalues = mo_set_old%eigenvalues

      ALLOCATE (mo_set_new%occupation_numbers(nmo))
      mo_set_new%occupation_numbers = mo_set_old%occupation_numbers

   END SUBROUTINE duplicate_mo_set

! **************************************************************************************************
!> \brief Allocates a mo set and partially initializes it (nao,nmo,nelectron,
!>        and flexible_electron_count are valid).
!>        For the full initialization you need to call init_mo_set
!> \param mo_set the mo_set to allocate
!> \param nao number of atom orbitals
!> \param nmo number of molecular orbitals
!> \param nelectron number of electrons
!> \param n_el_f ...
!> \param maxocc maximum occupation of an orbital (LDA: 2, LSD:1)
!> \param flexible_electron_count the number of electrons can be changed
!> \date 15.05.2001
!> \par History
!>      11.2002 splitted initialization in two phases [fawzi]
!> \author Matthias Krack
! **************************************************************************************************
   SUBROUTINE allocate_mo_set(mo_set, nao, nmo, nelectron, n_el_f, maxocc, &
                              flexible_electron_count)

      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set
      INTEGER, INTENT(IN)                                :: nao, nmo, nelectron
      REAL(KIND=dp), INTENT(IN)                          :: n_el_f, maxocc, flexible_electron_count

      mo_set%maxocc = maxocc
      mo_set%nelectron = nelectron
      mo_set%n_el_f = n_el_f
      mo_set%nao = nao
      mo_set%nmo = nmo
      mo_set%homo = 0
      mo_set%lfomo = 0
      mo_set%uniform_occupation = .TRUE.
      mo_set%kTS = 0.0_dp
      mo_set%mu = 0.0_dp
      mo_set%flexible_electron_count = flexible_electron_count

      NULLIFY (mo_set%eigenvalues)
      NULLIFY (mo_set%occupation_numbers)
      NULLIFY (mo_set%mo_coeff)
      NULLIFY (mo_set%mo_coeff_b)
      mo_set%use_mo_coeff_b = .FALSE.

   END SUBROUTINE allocate_mo_set

! **************************************************************************************************
!> \brief initializes an allocated mo_set.
!>      eigenvalues, mo_coeff, occupation_numbers are valid only
!>      after this call.
!> \param mo_set the mo_set to initialize
!> \param fm_pool a pool out which you initialize the mo_set
!> \param fm_ref  a reference  matrix from which you initialize the mo_set
!> \param fm_struct ...
!> \param name ...
!> \par History
!>      11.2002 revamped [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE init_mo_set(mo_set, fm_pool, fm_ref, fm_struct, name)

      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set
      TYPE(cp_fm_pool_type), INTENT(IN), OPTIONAL        :: fm_pool
      TYPE(cp_fm_type), INTENT(IN), OPTIONAL             :: fm_ref
      TYPE(cp_fm_struct_type), OPTIONAL, POINTER         :: fm_struct
      CHARACTER(LEN=*), INTENT(in)                       :: name

      INTEGER                                            :: nao, nmo, nomo

      CPASSERT(.NOT. ASSOCIATED(mo_set%eigenvalues))
      CPASSERT(.NOT. ASSOCIATED(mo_set%occupation_numbers))
      CPASSERT(.NOT. ASSOCIATED(mo_set%mo_coeff))

      CPASSERT(PRESENT(fm_pool) .NEQV. (PRESENT(fm_ref) .NEQV. PRESENT(fm_struct)))
      NULLIFY (mo_set%mo_coeff)
      IF (PRESENT(fm_pool)) THEN
         ALLOCATE (mo_set%mo_coeff)
         CALL fm_pool_create_fm(fm_pool, mo_set%mo_coeff, name=name)
      ELSE IF (PRESENT(fm_ref)) THEN
         ALLOCATE (mo_set%mo_coeff)
         CALL cp_fm_create(mo_set%mo_coeff, fm_ref%matrix_struct, name=name)
      ELSE IF (PRESENT(fm_struct)) THEN
         ALLOCATE (mo_set%mo_coeff)
         CPASSERT(ASSOCIATED(fm_struct))
         CALL cp_fm_create(mo_set%mo_coeff, fm_struct, name=name)
      END IF
      CALL cp_fm_get_info(mo_set%mo_coeff, nrow_global=nao, ncol_global=nmo)

      CPASSERT(nao >= mo_set%nao)
      CPASSERT(nmo >= mo_set%nmo)

      ALLOCATE (mo_set%eigenvalues(nmo))
      mo_set%eigenvalues(:) = 0.0_dp

      ALLOCATE (mo_set%occupation_numbers(nmo))
      ! Initialize MO occupations
      mo_set%occupation_numbers(:) = 0.0_dp
      ! Quick return, if no electrons are available
      IF (mo_set%nelectron == 0) THEN
         RETURN
      END IF

      IF (MODULO(mo_set%nelectron, INT(mo_set%maxocc)) == 0) THEN
         nomo = NINT(mo_set%nelectron/mo_set%maxocc)
         mo_set%occupation_numbers(1:nomo) = mo_set%maxocc
      ELSE
         nomo = INT(mo_set%nelectron/mo_set%maxocc) + 1
         ! Initialize MO occupations
         mo_set%occupation_numbers(1:nomo - 1) = mo_set%maxocc
         mo_set%occupation_numbers(nomo) = mo_set%nelectron - (nomo - 1)*mo_set%maxocc
      END IF

      CPASSERT(nmo >= nomo)
      CPASSERT((SIZE(mo_set%occupation_numbers) == nmo))

      mo_set%homo = nomo
      mo_set%lfomo = nomo + 1
      mo_set%mu = mo_set%eigenvalues(nomo)

   END SUBROUTINE init_mo_set

! **************************************************************************************************
!> \brief make the beta orbitals explicitly equal to the alpha orbitals
!>       effectively copying the orbital data
!> \param mo_array ...
!> \param convert_dbcsr ...
!> \par History
!>      10.2004 created [Joost VandeVondele]
! **************************************************************************************************
   SUBROUTINE mo_set_restrict(mo_array, convert_dbcsr)
      TYPE(mo_set_type), DIMENSION(2), INTENT(IN)        :: mo_array
      LOGICAL, INTENT(in), OPTIONAL                      :: convert_dbcsr

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'mo_set_restrict'

      INTEGER                                            :: handle
      LOGICAL                                            :: my_convert_dbcsr

      CALL timeset(routineN, handle)

      my_convert_dbcsr = .FALSE.
      IF (PRESENT(convert_dbcsr)) my_convert_dbcsr = convert_dbcsr

      CPASSERT(mo_array(1)%nmo >= mo_array(2)%nmo)

      ! first nmo_beta orbitals are copied from alpha to beta
      IF (my_convert_dbcsr) THEN !fm->dbcsr
         CALL dbcsr_copy_columns_hack(mo_array(2)%mo_coeff_b, mo_array(1)%mo_coeff_b, & !fm->dbcsr
                                      mo_array(2)%nmo, 1, 1, & !fm->dbcsr
                                      para_env=mo_array(1)%mo_coeff%matrix_struct%para_env, & !fm->dbcsr
                                      blacs_env=mo_array(1)%mo_coeff%matrix_struct%context) !fm->dbcsr
      ELSE !fm->dbcsr
         CALL cp_fm_to_fm(mo_array(1)%mo_coeff, mo_array(2)%mo_coeff, mo_array(2)%nmo)
      END IF

      CALL timestop(handle)

   END SUBROUTINE mo_set_restrict

! **************************************************************************************************
!> \brief   Deallocate a wavefunction data structure.
!> \param mo_set ...
!> \date    15.05.2001
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE deallocate_mo_set(mo_set)

      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set

      IF (ASSOCIATED(mo_set%eigenvalues)) THEN
         DEALLOCATE (mo_set%eigenvalues)
         NULLIFY (mo_set%eigenvalues)
      END IF
      IF (ASSOCIATED(mo_set%occupation_numbers)) THEN
         DEALLOCATE (mo_set%occupation_numbers)
         NULLIFY (mo_set%occupation_numbers)
      END IF
      IF (ASSOCIATED(mo_set%mo_coeff)) THEN
         CALL cp_fm_release(mo_set%mo_coeff)
         DEALLOCATE (mo_set%mo_coeff)
         NULLIFY (mo_set%mo_coeff)
      END IF
      IF (ASSOCIATED(mo_set%mo_coeff_b)) CALL dbcsr_release_p(mo_set%mo_coeff_b)

   END SUBROUTINE deallocate_mo_set

! **************************************************************************************************
!> \brief   Get the components of a MO set data structure.
!> \param mo_set ...
!> \param maxocc ...
!> \param homo ...
!> \param lfomo ...
!> \param nao ...
!> \param nelectron ...
!> \param n_el_f ...
!> \param nmo ...
!> \param eigenvalues ...
!> \param occupation_numbers ...
!> \param mo_coeff ...
!> \param mo_coeff_b ...
!> \param uniform_occupation ...
!> \param kTS ...
!> \param mu ...
!> \param flexible_electron_count ...
!> \date    22.04.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE get_mo_set(mo_set, maxocc, homo, lfomo, nao, nelectron, n_el_f, nmo, &
                         eigenvalues, occupation_numbers, mo_coeff, mo_coeff_b, &
                         uniform_occupation, kTS, mu, flexible_electron_count)

      TYPE(mo_set_type), INTENT(IN)                      :: mo_set
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: maxocc
      INTEGER, INTENT(OUT), OPTIONAL                     :: homo, lfomo, nao, nelectron
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: n_el_f
      INTEGER, INTENT(OUT), OPTIONAL                     :: nmo
      REAL(KIND=dp), DIMENSION(:), OPTIONAL, POINTER     :: eigenvalues, occupation_numbers
      TYPE(cp_fm_type), OPTIONAL, POINTER                :: mo_coeff
      TYPE(dbcsr_type), OPTIONAL, POINTER                :: mo_coeff_b
      LOGICAL, INTENT(OUT), OPTIONAL                     :: uniform_occupation
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: kTS, mu, flexible_electron_count

      IF (PRESENT(maxocc)) maxocc = mo_set%maxocc
      IF (PRESENT(homo)) homo = mo_set%homo
      IF (PRESENT(lfomo)) lfomo = mo_set%lfomo
      IF (PRESENT(nao)) nao = mo_set%nao
      IF (PRESENT(nelectron)) nelectron = mo_set%nelectron
      IF (PRESENT(n_el_f)) n_el_f = mo_set%n_el_f
      IF (PRESENT(nmo)) nmo = mo_set%nmo
      IF (PRESENT(eigenvalues)) eigenvalues => mo_set%eigenvalues
      IF (PRESENT(occupation_numbers)) THEN
         occupation_numbers => mo_set%occupation_numbers
      END IF
      IF (PRESENT(mo_coeff)) mo_coeff => mo_set%mo_coeff
      IF (PRESENT(mo_coeff_b)) mo_coeff_b => mo_set%mo_coeff_b
      IF (PRESENT(uniform_occupation)) uniform_occupation = mo_set%uniform_occupation
      IF (PRESENT(kTS)) kTS = mo_set%kTS
      IF (PRESENT(mu)) mu = mo_set%mu
      IF (PRESENT(flexible_electron_count)) flexible_electron_count = mo_set%flexible_electron_count

   END SUBROUTINE get_mo_set

! **************************************************************************************************
!> \brief   Set the components of a MO set data structure.
!> \param mo_set ...
!> \param maxocc ...
!> \param homo ...
!> \param lfomo ...
!> \param nao ...
!> \param nelectron ...
!> \param n_el_f ...
!> \param nmo ...
!> \param eigenvalues ...
!> \param occupation_numbers ...
!> \param uniform_occupation ...
!> \param kTS ...
!> \param mu ...
!> \param flexible_electron_count ...
!> \date    22.04.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE set_mo_set(mo_set, maxocc, homo, lfomo, nao, nelectron, n_el_f, nmo, &
                         eigenvalues, occupation_numbers, uniform_occupation, &
                         kTS, mu, flexible_electron_count)

      TYPE(mo_set_type), INTENT(INOUT)                   :: mo_set
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: maxocc
      INTEGER, INTENT(IN), OPTIONAL                      :: homo, lfomo, nao, nelectron
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: n_el_f
      INTEGER, INTENT(IN), OPTIONAL                      :: nmo
      REAL(KIND=dp), DIMENSION(:), OPTIONAL, POINTER     :: eigenvalues, occupation_numbers
      LOGICAL, INTENT(IN), OPTIONAL                      :: uniform_occupation
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: kTS, mu, flexible_electron_count

      IF (PRESENT(maxocc)) mo_set%maxocc = maxocc
      IF (PRESENT(homo)) mo_set%homo = homo
      IF (PRESENT(lfomo)) mo_set%lfomo = lfomo
      IF (PRESENT(nao)) mo_set%nao = nao
      IF (PRESENT(nelectron)) mo_set%nelectron = nelectron
      IF (PRESENT(n_el_f)) mo_set%n_el_f = n_el_f
      IF (PRESENT(nmo)) mo_set%nmo = nmo
      IF (PRESENT(eigenvalues)) THEN
         IF (ASSOCIATED(mo_set%eigenvalues)) THEN
            DEALLOCATE (mo_set%eigenvalues)
         END IF
         mo_set%eigenvalues => eigenvalues
      END IF
      IF (PRESENT(occupation_numbers)) THEN
         IF (ASSOCIATED(mo_set%occupation_numbers)) THEN
            DEALLOCATE (mo_set%occupation_numbers)
         END IF
         mo_set%occupation_numbers => occupation_numbers
      END IF
      IF (PRESENT(uniform_occupation)) mo_set%uniform_occupation = uniform_occupation
      IF (PRESENT(kTS)) mo_set%kTS = kTS
      IF (PRESENT(mu)) mo_set%mu = mu
      IF (PRESENT(flexible_electron_count)) mo_set%flexible_electron_count = flexible_electron_count

   END SUBROUTINE set_mo_set

! **************************************************************************************************
!> \brief   Check if the set of MOs in mo_set specifed by the MO index range [first_mo,last_mo]
!>          an integer occupation within a tolerance.
!> \param   mo_set :: MO set for which the uniform occupation will be checked
!> \param   first_mo :: Index of first MO for the checked MO range
!> \param   last_mo :: Index of last MO for the checked MO range
!> \param   occupation :: Requested uniform MO occupation with the MO range
!> \param   tolerance :: Requested numerical tolerance for an integer occupation
!> \return  has_uniform_occupation :: boolean, true if an integer occupation is found otherwise false
!> \par History
!>      04.08.2021 Created (MK)
!> \author  Matthias Krack (MK)
!> \version 1.0
! **************************************************************************************************
   FUNCTION has_uniform_occupation(mo_set, first_mo, last_mo, occupation, tolerance)

      TYPE(mo_set_type), INTENT(IN)                      :: mo_set
      INTEGER, INTENT(IN), OPTIONAL                      :: first_mo, last_mo
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: occupation, tolerance
      LOGICAL                                            :: has_uniform_occupation

      INTEGER                                            :: my_first_mo, my_last_mo
      REAL(KIND=dp)                                      :: my_occupation, my_tolerance

      has_uniform_occupation = .FALSE.

      IF (PRESENT(first_mo)) THEN
         CPASSERT(first_mo >= LBOUND(mo_set%eigenvalues, 1))
         my_first_mo = first_mo
      ELSE
         my_first_mo = LBOUND(mo_set%eigenvalues, 1)
      END IF

      IF (PRESENT(last_mo)) THEN
         CPASSERT(last_mo <= UBOUND(mo_set%eigenvalues, 1))
         my_last_mo = last_mo
      ELSE
         my_last_mo = UBOUND(mo_set%eigenvalues, 1)
      END IF

      IF (PRESENT(occupation)) THEN
         my_occupation = occupation
      ELSE
         my_occupation = mo_set%maxocc
      END IF

      IF (PRESENT(tolerance)) THEN
         my_tolerance = tolerance
      ELSE
         my_tolerance = EPSILON(0.0_dp)
      END IF

      has_uniform_occupation = ALL(ABS(mo_set%occupation_numbers(my_first_mo:my_last_mo) - my_occupation) < my_tolerance)

   END FUNCTION has_uniform_occupation

END MODULE qs_mo_types
