!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief a module to allow simple internal preprocessing in input files.
!> \par History
!>      - standalone proof-of-concept implementation (20.02.2008,AK)
!>      - integration into cp2k (22.02.2008,tlaino)
!>      - variables added (25.02.2008,AK)
!> \author Axel Kohlmeyer [AK] - CMM/UPenn Philadelphia
!> \date 25.02.2008
! **************************************************************************************************
MODULE cp_parser_ilist_types

#include "../base/base_uses.f90"
   IMPLICIT NONE
   PRIVATE

   TYPE ilist_type
      LOGICAL                              :: in_use = .FALSE.
      INTEGER                              :: nel_list = HUGE(0)
      INTEGER                              :: istart = HUGE(0), iend = HUGE(0)
      INTEGER                              :: ipresent = HUGE(0)
   END TYPE ilist_type

   PUBLIC :: ilist_type, create_ilist_type, release_ilist_type
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_parser_ilist_types'

CONTAINS

! ****************************************************************************
!> \brief creates the integer listing type
!> \param ilist ...
!> \date  08.2008
!> \author Teodoro Laino [tlaino] - University of Zurich
! **************************************************************************************************
   SUBROUTINE create_ilist_type(ilist)
      TYPE(ilist_type), POINTER                          :: ilist

      CPASSERT(.NOT. ASSOCIATED(ilist))
      ALLOCATE (ilist)

   END SUBROUTINE create_ilist_type

! ****************************************************************************
!> \brief creates the integer listing type
!> \param ilist ...
!> \date  08.2008
!> \author Teodoro Laino [tlaino] - University of Zurich
! **************************************************************************************************
   SUBROUTINE release_ilist_type(ilist)
      TYPE(ilist_type), POINTER                          :: ilist

      CPASSERT(ASSOCIATED(ilist))
      DEALLOCATE (ilist)
   END SUBROUTINE release_ilist_type

END MODULE cp_parser_ilist_types
